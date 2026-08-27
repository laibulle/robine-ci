defmodule Robine.Adapters.Deployments.DockerEnvironment do
  @moduledoc "Bounded Docker convergence for native single-host deployment environments."
  @behaviour Robine.Deployments.Ports.ContainerRuntime

  alias Robine.Deployments.Domain.{Environment, ServiceSpec}

  @instance_label "io.robine.instance"
  @environment_label "io.robine.environment"
  @role_label "io.robine.service-role"
  @spec_label "io.robine.deployment-spec"
  @persistent_label "io.robine.persistent"

  @impl true
  def converge(environment, kind, resolved_secrets, options \\ [])

  def converge(%Environment{} = environment, kind, resolved_secrets, options)
      when kind in [:application, :platform] and is_map(resolved_secrets) do
    docker = Keyword.get(options, :docker, &docker/1)
    instance_id = Keyword.get(options, :instance_id, instance_id())
    service_roles = Keyword.get(options, :service_roles, ServiceSpec.roles())

    with {:ok, artifact} <- deployment_artifact(environment, options),
         :ok <- ensure_network(environment, instance_id, docker),
         {:ok, results} <-
           converge_services(
             environment,
             kind,
             resolved_secrets,
             instance_id,
             docker,
             service_roles,
             artifact
           ) do
      {:ok, %{network: environment.network_name, services: results}}
    end
  end

  def converge(%Environment{}, _kind, _resolved_secrets, _options),
    do: {:error, :invalid_deployment_kind}

  @spec migrate(Environment.t(), Path.t(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def migrate(%Environment{} = environment, release_path, digest, secrets, options \\ []) do
    docker = Keyword.get(options, :docker, &docker/1)
    instance_id = Keyword.get(options, :instance_id, instance_id())
    application = Enum.find(environment.services, &(&1.role == :application))

    with true <- safe_release_path?(environment, release_path, digest),
         %ServiceSpec{} = application <- application,
         {:ok, values} <- resolve_environment(application, secrets),
         :ok <- pull_image(application, docker) do
      with_temporary_environment(values, fn env_file ->
        arguments =
          [
            "container",
            "run",
            "--rm",
            "--network",
            environment.network_name,
            "--workdir",
            "/opt/robine",
            "--volume",
            "#{release_path}:/opt/robine:ro",
            "--label",
            "#{@instance_label}=#{instance_id}",
            "--label",
            "#{@environment_label}=#{environment.id}"
          ] ++
            env_file_args(env_file) ++
            [
              application.image,
              "/opt/robine/bin/robine",
              "eval",
              "Robine.Runtime.Release.migrate()"
            ]

        case docker.(arguments) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:migration_failed, reason}}
        end
      end)
    else
      false -> {:error, :unsafe_release_path}
      nil -> {:error, :application_service_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_network(environment, instance_id, docker) do
    case inspect_labels(:network, environment.network_name, docker) do
      {:ok, labels} ->
        if owned?(labels, instance_id, environment.id),
          do: :ok,
          else: {:error, {:network_ownership_conflict, environment.network_name}}

      {:error, :not_found} ->
        case docker.([
               "network",
               "create",
               "--label",
               "#{@instance_label}=#{instance_id}",
               "--label",
               "#{@environment_label}=#{environment.id}",
               environment.network_name
             ]) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:network_create, reason}}
        end

      {:error, reason} ->
        {:error, {:network_inspect, reason}}
    end
  end

  defp converge_services(environment, kind, secrets, instance_id, docker, service_roles, artifact) do
    environment.services
    |> Enum.filter(&(&1.role in service_roles))
    |> Enum.reduce_while({:ok, []}, fn service, {:ok, results} ->
      case converge_service(
             environment,
             service,
             kind,
             secrets,
             instance_id,
             docker,
             artifact
           ) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp converge_service(
         environment,
         %ServiceSpec{} = service,
         kind,
         secrets,
         instance_id,
         docker,
         artifact
       ) do
    with {:ok, resolved_environment} <- resolve_environment(service, secrets),
         :ok <- ensure_volumes(environment, service, instance_id, docker),
         {:ok, observed} <-
           observe_service(
             environment,
             service,
             instance_id,
             desired_digest(service, artifact),
             docker
           ) do
      decide_convergence(
        environment,
        service,
        kind,
        resolved_environment,
        observed,
        instance_id,
        docker,
        artifact
      )
    end
  end

  defp decide_convergence(
         _environment,
         service,
         _kind,
         _environment_values,
         :current,
         _instance,
         _docker,
         _artifact
       ) do
    {:ok, %{name: service.name, role: service.role, action: :unchanged}}
  end

  defp decide_convergence(
         _environment,
         service,
         :application,
         _values,
         observed,
         _instance,
         _docker,
         _artifact
       )
       when service.role != :application do
    {:error, {:persistent_service_not_current, service.name, observed}}
  end

  defp decide_convergence(
         environment,
         service,
         kind,
         values,
         observed,
         instance_id,
         docker,
         artifact
       ) do
    with :ok <- maybe_remove_changed(service, observed, docker),
         :ok <- pull_image(service, docker),
         :ok <- create_service(environment, service, values, instance_id, docker, artifact),
         :ok <- start_service(service, docker) do
      action = if observed == :missing, do: :created, else: :replaced
      {:ok, %{name: service.name, role: service.role, action: action, kind: kind}}
    end
  end

  defp observe_service(environment, service, instance_id, desired_digest, docker) do
    case inspect_labels(:container, service.name, docker) do
      {:ok, labels} ->
        cond do
          not owned?(labels, instance_id, environment.id) ->
            {:error, {:container_ownership_conflict, service.name}}

          labels[@role_label] != Atom.to_string(service.role) ->
            {:error, {:container_role_conflict, service.name}}

          labels[@spec_label] == desired_digest ->
            {:ok, :current}

          true ->
            {:ok, :changed}
        end

      {:error, :not_found} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:container_inspect, service.name, reason}}
    end
  end

  defp ensure_volumes(environment, service, instance_id, docker) do
    Enum.reduce_while(service.volumes, :ok, fn volume, :ok ->
      case inspect_labels(:volume, volume.name, docker) do
        {:ok, labels} ->
          if owned?(labels, instance_id, environment.id),
            do: {:cont, :ok},
            else: {:halt, {:error, {:volume_ownership_conflict, volume.name}}}

        {:error, :not_found} ->
          case docker.([
                 "volume",
                 "create",
                 "--label",
                 "#{@instance_label}=#{instance_id}",
                 "--label",
                 "#{@environment_label}=#{environment.id}",
                 volume.name
               ]) do
            {:ok, _output} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:volume_create, volume.name, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:volume_inspect, volume.name, reason}}}
      end
    end)
  end

  defp resolve_environment(service, secrets) do
    Enum.reduce_while(service.secret_environment, {:ok, service.environment}, fn
      {key, secret_name}, {:ok, values} ->
        case Map.fetch(secrets, secret_name) do
          {:ok, value} when is_binary(value) -> {:cont, {:ok, Map.put(values, key, value)}}
          _missing -> {:halt, {:error, {:missing_deployment_secret, secret_name}}}
        end
    end)
  end

  defp maybe_remove_changed(_service, :missing, _docker), do: :ok

  defp maybe_remove_changed(service, :changed, docker) do
    case docker.(["container", "rm", "--force", service.name]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:container_remove, service.name, reason}}
    end
  end

  defp pull_image(service, docker) do
    case docker.(["image", "pull", service.image]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:image_pull, service.name, reason}}
    end
  end

  defp create_service(environment, service, environment_values, instance_id, docker, artifact) do
    with_temporary_environment(environment_values, fn env_file ->
      arguments =
        [
          "container",
          "create",
          "--name",
          service.name,
          "--restart",
          "unless-stopped",
          "--network",
          environment.network_name,
          "--label",
          "#{@instance_label}=#{instance_id}",
          "--label",
          "#{@environment_label}=#{environment.id}",
          "--label",
          "#{@role_label}=#{service.role}",
          "--label",
          "#{@spec_label}=#{desired_digest(service, artifact)}",
          "--label",
          "#{@persistent_label}=#{service.role != :application}"
        ] ++
          env_file_args(env_file) ++
          release_args(service, artifact) ++
          volume_args(service.volumes) ++ [service.image] ++ service.command

      case docker.(arguments) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, {:container_create, service.name, reason}}
      end
    end)
  end

  defp start_service(service, docker) do
    case docker.(["container", "start", service.name]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:container_start, service.name, reason}}
    end
  end

  defp with_temporary_environment(values, callback) when map_size(values) == 0,
    do: callback.(nil)

  defp with_temporary_environment(values, callback) do
    path = Path.join(System.tmp_dir!(), "robine-deployment-env-#{Ecto.UUID.generate()}")

    content =
      values
      |> Enum.sort()
      |> Enum.map_join("", fn {key, value} -> "#{key}=#{escape_environment(value)}\n" end)

    try do
      with :ok <- File.write(path, content, [:binary, :exclusive]),
           :ok <- File.chmod(path, 0o600) do
        callback.(path)
      end
    after
      File.rm(path)
    end
  end

  defp escape_environment(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end

  defp env_file_args(nil), do: []
  defp env_file_args(path), do: ["--env-file", path]

  defp volume_args(volumes) do
    Enum.flat_map(volumes, fn volume ->
      suffix = if volume.read_only, do: ":ro", else: ""
      ["--volume", "#{volume.name}:#{volume.mount_path}#{suffix}"]
    end)
  end

  defp deployment_artifact(environment, options) do
    path = Keyword.get(options, :release_path)
    digest = Keyword.get(options, :artifact_digest)

    cond do
      is_nil(path) and is_nil(digest) -> {:ok, nil}
      safe_release_path?(environment, path, digest) -> {:ok, %{path: path, digest: digest}}
      true -> {:error, :unsafe_release_path}
    end
  end

  defp desired_digest(%ServiceSpec{role: :application, spec_digest: service_digest}, %{
         digest: artifact_digest
       }) do
    :crypto.hash(:sha256, service_digest <> artifact_digest) |> Base.encode16(case: :lower)
  end

  defp desired_digest(%ServiceSpec{spec_digest: digest}, _artifact), do: digest

  defp release_args(%ServiceSpec{role: :application}, %{path: path}),
    do: ["--volume", "#{path}:/opt/robine:ro", "--workdir", "/opt/robine"]

  defp release_args(_service, _artifact), do: []

  defp safe_release_path?(environment, path, digest)
       when is_binary(path) and is_binary(digest) and byte_size(digest) == 64 do
    expected = Path.join([environment.deployment_root, "releases", digest])
    Path.expand(path) == path and path == expected
  end

  defp safe_release_path?(_environment, _path, _digest), do: false

  defp inspect_labels(type, name, docker) do
    command =
      case type do
        :container -> ["container", "inspect", "--format", "{{json .Config.Labels}}", name]
        :network -> ["network", "inspect", "--format", "{{json .Labels}}", name]
        :volume -> ["volume", "inspect", "--format", "{{json .Labels}}", name]
      end

    case docker.(command) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, labels} when is_map(labels) -> {:ok, labels}
          _invalid -> {:error, :invalid_inspect_output}
        end

      {:error, %{output: output}} when is_binary(output) ->
        if String.contains?(output, ["No such", "not found"]),
          do: {:error, :not_found},
          else: {:error, :docker_unavailable}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp owned?(labels, instance_id, environment_id) do
    labels[@instance_label] == instance_id and labels[@environment_label] == environment_id
  end

  defp instance_id do
    Application.get_env(:robine, :instance_id, "default")
    |> to_string()
  end

  defp docker(arguments) do
    task = Task.async(fn -> System.cmd("docker", arguments, stderr_to_stdout: true) end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, String.slice(output, 0, 64_000)}

      {:ok, {output, status}} ->
        {:error, %{status: status, output: String.slice(output, 0, 64_000)}}

      nil ->
        {:error, :timeout}
    end
  rescue
    error -> {:error, {:docker, error.__struct__}}
  end
end
