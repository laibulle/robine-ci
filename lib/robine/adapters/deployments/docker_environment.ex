defmodule Robine.Adapters.Deployments.DockerEnvironment do
  @moduledoc "Bounded Docker convergence for native single-host deployment environments."
  @behaviour Robine.Deployments.Ports.ContainerRuntime

  alias Robine.Deployments.Domain.{Environment, ServiceSpec}

  @instance_label "io.robine.instance"
  @environment_label "io.robine.environment"
  @role_label "io.robine.service-role"
  @spec_label "io.robine.deployment-spec"
  @persistent_label "io.robine.persistent"
  @bundled_runner_role "bundled_runner"
  @bundled_runner_image "docker:28.5.2-cli@sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d"
  @docker_socket "/var/run/docker.sock"

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
           ),
         {:ok, results} <-
           converge_bundled_runner(
             environment,
             kind,
             instance_id,
             docker,
             service_roles,
             artifact,
             results
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

  defp converge_bundled_runner(
         environment,
         kind,
         instance_id,
         docker,
         service_roles,
         artifact,
         results
       ) do
    application = Enum.find(environment.services, &(&1.role == :application))

    if is_map(artifact) and :application in service_roles and match?(%ServiceSpec{}, application) do
      case bundled_runner_mode(application) do
        {:ok, true} ->
          with {:ok, runner} <- bundled_runner_spec(environment, application, artifact),
               :ok <- ensure_volumes(environment, runner.volumes, instance_id, docker),
               {:ok, observed} <-
                 observe_bundled_runner(environment, runner, instance_id, docker),
               {:ok, result} <-
                 decide_bundled_runner_convergence(
                   environment,
                   runner,
                   kind,
                   observed,
                   instance_id,
                   docker,
                   artifact
                 ) do
            {:ok, results ++ [result]}
          end

        {:ok, false} ->
          remove_disabled_bundled_runner(environment, application, instance_id, docker, results)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, results}
    end
  end

  defp decide_bundled_runner_convergence(
         _environment,
         runner,
         _kind,
         :current,
         _instance_id,
         _docker,
         _artifact
       ) do
    {:ok, %{name: runner.name, role: :bundled_runner, action: :unchanged}}
  end

  defp decide_bundled_runner_convergence(
         environment,
         runner,
         kind,
         observed,
         instance_id,
         docker,
         artifact
       ) do
    with :ok <- maybe_remove_changed(runner, observed, docker),
         :ok <- pull_image(runner, docker),
         :ok <- create_bundled_runner(environment, runner, instance_id, docker, artifact),
         :ok <- start_service(runner, docker) do
      action = if observed == :missing, do: :created, else: :replaced
      {:ok, %{name: runner.name, role: :bundled_runner, action: action, kind: kind}}
    end
  end

  defp observe_bundled_runner(environment, runner, instance_id, docker) do
    case inspect_labels(:container, runner.name, docker) do
      {:ok, labels} ->
        cond do
          not owned?(labels, instance_id, environment.id) ->
            {:error, {:container_ownership_conflict, runner.name}}

          labels[@role_label] != @bundled_runner_role ->
            {:error, {:container_role_conflict, runner.name}}

          labels[@spec_label] == runner.spec_digest ->
            {:ok, :current}

          true ->
            {:ok, :changed}
        end

      {:error, :not_found} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:container_inspect, runner.name, reason}}
    end
  end

  defp remove_disabled_bundled_runner(environment, application, instance_id, docker, results) do
    name = bounded_resource_name(application.name, "runner")

    case inspect_labels(:container, name, docker) do
      {:error, :not_found} ->
        {:ok, results}

      {:ok, labels} ->
        if owned?(labels, instance_id, environment.id) and
             labels[@role_label] == @bundled_runner_role do
          case docker.(["container", "rm", "--force", name]) do
            {:ok, _output} ->
              {:ok, results ++ [%{name: name, role: :bundled_runner, action: :removed}]}

            {:error, reason} ->
              {:error, {:container_remove, name, reason}}
          end
        else
          {:error, {:container_ownership_conflict, name}}
        end

      {:error, reason} ->
        {:error, {:container_inspect, name, reason}}
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
         {:ok, owned_volumes} <- owned_volumes(service, artifact),
         :ok <- ensure_volumes(environment, owned_volumes, instance_id, docker),
         {:ok, observed} <-
           observe_service(
             environment,
             service,
             instance_id,
             desired_digest(service, artifact, owned_volumes),
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
        artifact,
        owned_volumes
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
         _artifact,
         _owned_volumes
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
         _artifact,
         _owned_volumes
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
         artifact,
         owned_volumes
       ) do
    with :ok <- maybe_remove_changed(service, observed, docker),
         :ok <- pull_image(service, docker),
         :ok <-
           create_service(
             environment,
             service,
             values,
             instance_id,
             docker,
             artifact,
             owned_volumes
           ),
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

  defp ensure_volumes(environment, volumes, instance_id, docker) do
    Enum.reduce_while(volumes, :ok, fn volume, :ok ->
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

  defp bundled_runner_spec(environment, application, artifact) do
    with {:ok, volumes} <- bundled_runner_volumes(application),
         {:ok, runner_environment} <- bundled_runner_environment(environment, application) do
      name = bounded_resource_name(application.name, "runner")

      digest =
        [
          application.spec_digest,
          artifact.digest,
          @bundled_runner_image,
          Enum.sort(runner_environment),
          Enum.map(volumes, &{&1.name, &1.mount_path})
        ]
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         name: name,
         image: @bundled_runner_image,
         environment: runner_environment,
         volumes: volumes,
         spec_digest: digest
       }}
    end
  end

  defp bundled_runner_environment(environment, application) do
    values = application.environment

    with {:ok, public_url} <- bundled_public_url(values, environment.verification.url),
         {:ok, runner_name} <- runner_name(values, environment),
         {:ok, namespace} <- resource_namespace(values, environment),
         {:ok, cpu_millis} <-
           bounded_integer(values, "ROBINE_RUNNER_CPU_MILLIS", 2_000, 100, 256_000),
         {:ok, memory_bytes} <-
           bounded_integer(
             values,
             "ROBINE_RUNNER_MEMORY_BYTES",
             4_294_967_296,
             67_108_864,
             1_099_511_627_776
           ),
         {:ok, pids_limit} <-
           bounded_integer(values, "ROBINE_RUNNER_PIDS_LIMIT", 512, 16, 1_000_000) do
      {:ok,
       %{
         "ROBINE_PUBLIC_URL" => public_url,
         "ROBINE_BUNDLED_RUNNER_NAME" => runner_name,
         "ROBINE_RUNNER_RESOURCE_NAMESPACE" => namespace,
         "ROBINE_RUNNER_CPU_MILLIS" => Integer.to_string(cpu_millis),
         "ROBINE_RUNNER_MEMORY_BYTES" => Integer.to_string(memory_bytes),
         "ROBINE_RUNNER_PIDS_LIMIT" => Integer.to_string(pids_limit),
         "ROBINE_RUNNER_READY_FILE" => "/var/lib/robine-runner/ready"
       }}
    end
  end

  defp bundled_public_url(values, fallback) do
    {raw, explicit?} =
      case Map.fetch(values, "ROBINE_PUBLIC_URL") do
        {:ok, value} -> {value, true}
        :error -> {fallback, false}
      end

    uri = URI.parse(raw || "")

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         (not explicit? or uri.path in [nil, "", "/"]) do
      {:ok, URI.to_string(%{uri | path: nil}) |> String.trim_trailing("/")}
    else
      {:error, :invalid_bundled_runner_public_url}
    end
  end

  defp runner_name(values, environment) do
    value = Map.get(values, "ROBINE_BUNDLED_RUNNER_NAME", "#{environment.name}-local")
    normalized = if is_binary(value), do: String.trim(value), else: ""

    if normalized != "" and String.length(normalized) <= 80 and
         not String.contains?(normalized, ["\n", "\r", "\0"]),
       do: {:ok, normalized},
       else: {:error, :invalid_bundled_runner_name}
  end

  defp resource_namespace(values, environment) do
    value = Map.get(values, "ROBINE_RUNNER_RESOURCE_NAMESPACE", environment.name)

    if is_binary(value) and byte_size(value) in 1..80 and
         not String.contains?(value, [" ", "/", "\\", "\t", "\r", "\n"]),
       do: {:ok, value},
       else: {:error, :invalid_bundled_runner_resource_namespace}
  end

  defp bounded_integer(values, key, default, minimum, maximum) do
    value = Map.get(values, key, Integer.to_string(default))

    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= minimum and parsed <= maximum -> {:ok, parsed}
      _invalid -> {:error, :invalid_bundled_runner_resource_limit}
    end
  end

  defp bundled_runner_mode(application) do
    case Map.get(application.environment, "ROBINE_BUNDLED_RUNNER_ENABLED", "true") do
      value when value in ["1", "true"] -> {:ok, true}
      value when value in ["0", "false"] -> {:ok, false}
      _invalid -> {:error, :invalid_bundled_runner_enabled}
    end
  end

  defp bundled_runner_volumes(application) do
    state_path = "/var/lib/robine-runner"
    bootstrap_path = "/var/lib/robine-runner-bootstrap"

    cond do
      Enum.any?(application.volumes, &(&1.mount_path == state_path)) ->
        {:error, :bundled_runner_state_volume_exposed_to_application}

      true ->
        bootstrap =
          Enum.find(application.volumes, &(&1.mount_path == bootstrap_path)) ||
            %{
              name: bounded_resource_name(application.name, "runner-bootstrap"),
              mount_path: bootstrap_path,
              read_only: false
            }

        state = %{
          name: bounded_resource_name(application.name, "runner-state"),
          mount_path: state_path,
          read_only: false
        }

        if Enum.any?(application.volumes, &(&1.name == state.name)) do
          {:error, :bundled_runner_volume_conflict}
        else
          {:ok, [state, bootstrap]}
        end
    end
  end

  defp owned_volumes(%ServiceSpec{role: :application} = service, %{} = _artifact) do
    case bundled_runner_mode(service) do
      {:ok, true} ->
        with {:ok, implicit} <- bundled_runner_volumes(service) do
          merge_volumes(service.volumes, implicit)
        end

      {:ok, false} ->
        {:ok, service.volumes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp owned_volumes(service, _artifact), do: {:ok, service.volumes}

  defp mounted_volumes(%ServiceSpec{role: :application} = service, %{} = _artifact, owned) do
    case bundled_runner_mode(service) do
      {:ok, true} ->
        {:ok,
         Enum.reject(owned, fn volume ->
           volume.mount_path == "/var/lib/robine-runner"
         end)}

      {:ok, false} ->
        {:ok, service.volumes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mounted_volumes(service, _artifact, _owned), do: {:ok, service.volumes}

  defp merge_volumes(existing, implicit) do
    Enum.reduce_while(implicit, {:ok, existing}, fn volume, {:ok, volumes} ->
      cond do
        Enum.any?(volumes, &(&1.name == volume.name and &1.mount_path == volume.mount_path)) ->
          {:cont, {:ok, volumes}}

        Enum.any?(volumes, &(&1.name == volume.name or &1.mount_path == volume.mount_path)) ->
          {:halt, {:error, :bundled_runner_volume_conflict}}

        true ->
          {:cont, {:ok, volumes ++ [volume]}}
      end
    end)
  end

  defp bounded_resource_name(base, suffix) do
    candidate = "#{base}-#{suffix}"

    if byte_size(candidate) <= 63 do
      candidate
    else
      digest =
        :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower) |> binary_part(0, 8)

      prefix_length = 63 - byte_size(suffix) - byte_size(digest) - 2
      "#{String.slice(base, 0, prefix_length)}-#{digest}-#{suffix}"
    end
  end

  defp maybe_remove_changed(_service, :missing, _docker), do: :ok

  defp maybe_remove_changed(service, :changed, docker) do
    case docker.(["container", "rm", "--force", service.name]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:container_remove, service.name, reason}}
    end
  end

  defp create_bundled_runner(environment, runner, instance_id, docker, artifact) do
    environment_arguments =
      runner.environment
      |> Enum.sort()
      |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)

    arguments =
      [
        "container",
        "create",
        "--name",
        runner.name,
        "--restart",
        "unless-stopped",
        "--network",
        environment.network_name,
        "--label",
        "#{@instance_label}=#{instance_id}",
        "--label",
        "#{@environment_label}=#{environment.id}",
        "--label",
        "#{@role_label}=#{@bundled_runner_role}",
        "--label",
        "#{@spec_label}=#{runner.spec_digest}",
        "--label",
        "#{@persistent_label}=false",
        "--health-cmd",
        "test -s /var/lib/robine-runner/config.json && test -s /var/lib/robine-runner/ready && pgrep -f '/opt/robine/bin/rbe start --config /var/lib/robine-runner/config.json' >/dev/null",
        "--health-interval",
        "2s",
        "--health-timeout",
        "3s",
        "--health-retries",
        "60",
        "--health-start-period",
        "10s"
      ] ++
        environment_arguments ++
        ["--volume", "#{artifact.path}:/opt/robine:ro"] ++
        volume_args(runner.volumes) ++
        [
          "--volume",
          "#{@docker_socket}:#{@docker_socket}",
          runner.image,
          "/opt/robine/bin/start-bundled-runner"
        ]

    case docker.(arguments) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:container_create, runner.name, reason}}
    end
  end

  defp pull_image(service, docker) do
    case docker.(["image", "pull", service.image]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:image_pull, service.name, reason}}
    end
  end

  defp create_service(
         environment,
         service,
         environment_values,
         instance_id,
         docker,
         artifact,
         owned_volumes
       ) do
    with {:ok, mounted_volumes} <- mounted_volumes(service, artifact, owned_volumes) do
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
            "#{@spec_label}=#{desired_digest(service, artifact, owned_volumes)}",
            "--label",
            "#{@persistent_label}=#{service.role != :application}"
          ] ++
            env_file_args(env_file) ++
            release_args(service, artifact) ++
            volume_args(mounted_volumes) ++ [service.image] ++ service.command

        case docker.(arguments) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, {:container_create, service.name, reason}}
        end
      end)
    end
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

  defp desired_digest(
         %ServiceSpec{role: :application, spec_digest: service_digest},
         %{digest: artifact_digest},
         owned_volumes
       ) do
    volume_layout =
      Enum.map(owned_volumes, &{&1.name, &1.mount_path, Map.get(&1, :read_only, false)})

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({service_digest, artifact_digest, volume_layout})
    )
    |> Base.encode16(case: :lower)
  end

  defp desired_digest(%ServiceSpec{spec_digest: digest}, _artifact, _owned_volumes), do: digest

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
