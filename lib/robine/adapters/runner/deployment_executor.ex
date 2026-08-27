defmodule Robine.Adapters.Runner.DeploymentExecutor do
  @moduledoc "Executes one bounded native deployment offer on a dedicated host runner."

  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Adapters.Deployments.DockerEnvironment
  alias Robine.Adapters.Runner.RemoteClient
  alias Robine.Deployments.Domain.Environment
  alias Robine.Release.Checksums

  @spec run(map(), pid(), map()) :: :ok | {:error, term()}
  def run(offer, client, config) do
    with {:ok, deployment_id} <- identifier(offer["deployment_id"]),
         {:ok, idempotency_token} <- identifier(offer["idempotency_token"]),
         {:ok, kind} <- kind(offer["kind"]),
         {:ok, environment} <- environment(offer["environment"]),
         :ok <- authorized_root(environment.deployment_root, config) do
      steps = [
        {2, :converging_services, &prepare_and_converge(&1, offer, environment, kind, config)},
        {3, :migrating, &migrate(&1, environment, config)},
        {4, :activating, &activate(&1, environment, kind, config)},
        {5, :verifying, &{:ok, &1}}
      ]

      case run_steps(steps, %{}, deployment_id, idempotency_token, client, config) do
        {:ok, _state} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_steps(steps, state, deployment_id, idempotency_token, client, config) do
    Enum.reduce_while(steps, {:ok, state}, fn {sequence, phase, action}, {:ok, current} ->
      with :ok <-
             send_event(
               client,
               deployment_id,
               idempotency_token,
               sequence,
               phase,
               nil,
               config
             ),
           {:ok, updated} <- action.(current) do
        {:cont, {:ok, updated}}
      else
        {:error, reason} ->
          _ =
            send_event(
              client,
              deployment_id,
              idempotency_token,
              sequence + 1,
              :failed,
              safe_reason(reason),
              config
            )

          {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_and_converge(state, offer, environment, kind, config) do
    with {:ok, artifact} <- download_artifact(offer, config),
         {:ok, secrets} <- download_secrets(offer, config),
         {:ok, release_path} <- materialize_release(artifact, environment, config),
         {:ok, _result} <-
           DockerEnvironment.converge(
             environment,
             kind,
             secrets,
             runtime_options(config,
               service_roles: [:postgres, :object_storage],
               instance_id: config["runner_id"]
             )
           ) do
      {:ok,
       Map.merge(state, %{
         artifact: artifact,
         secrets: secrets,
         release_path: release_path
       })}
    end
  end

  defp migrate(
         %{artifact: artifact, secrets: secrets, release_path: release_path} = state,
         environment,
         config
       ) do
    if environment.migration_policy == :application_only do
      {:ok, state}
    else
      case DockerEnvironment.migrate(
             environment,
             release_path,
             artifact.digest,
             secrets,
             runtime_options(config, instance_id: config["runner_id"])
           ) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp activate(
         %{artifact: artifact, secrets: secrets, release_path: release_path} = state,
         environment,
         kind,
         config
       ) do
    roles = if kind == :platform, do: [:application, :ingress], else: [:application]

    case DockerEnvironment.converge(
           environment,
           kind,
           secrets,
           runtime_options(config,
             service_roles: roles,
             release_path: release_path,
             artifact_digest: artifact.digest,
             instance_id: config["runner_id"]
           )
         ) do
      {:ok, _result} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_artifact(%{"artifact_url" => url, "artifact" => expected}, config)
       when is_binary(url) and is_map(expected) do
    with {:ok, 200, body} <- authenticated_get(url, config, "application/gzip"),
         true <- byte_size(body) <= SafeTar.max_archive_bytes(),
         digest <- sha256(body),
         true <- digest == expected["digest"] do
      {:ok, %{body: body, digest: digest, filename: expected["filename"]}}
    else
      false -> {:error, :artifact_integrity_failed}
      {:ok, _status, _body} -> {:error, :artifact_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_artifact(_offer, _config), do: {:error, :invalid_deployment_offer}

  defp download_secrets(%{"secrets_url" => url}, config) when is_binary(url) do
    with {:ok, 200, body} <- authenticated_get(url, config, "application/json"),
         true <- byte_size(body) <= 1_048_576,
         {:ok, %{"secrets" => secrets}} when is_map(secrets) <- Jason.decode(body),
         true <- Enum.all?(secrets, fn {name, value} -> is_binary(name) and is_binary(value) end) do
      {:ok, secrets}
    else
      _invalid -> {:error, :deployment_secrets_unavailable}
    end
  end

  defp download_secrets(_offer, _config), do: {:error, :invalid_deployment_offer}

  defp authenticated_get(url, config, accept) do
    headers = [
      {"accept", accept},
      {"authorization", "Bearer #{config["credential"]}"},
      {"x-robine-runner-id", config["runner_id"]}
    ]

    request = Map.get(config, :request_adapter)

    case request do
      nil ->
        case Req.request(
               method: :get,
               url: url,
               headers: headers,
               retry: false,
               redirect: false,
               receive_timeout: 60_000,
               decode_body: false
             ) do
          {:ok, %{status: status, body: body}} when is_binary(body) -> {:ok, status, body}
          {:error, _exception} -> {:error, :deployment_transfer_unavailable}
        end

      adapter ->
        adapter.request(:get, url, headers, nil, config)
    end
  end

  defp materialize_release(artifact, environment, config) do
    target = Path.join([environment.deployment_root, "releases", artifact.digest])
    marker = Path.join(target, ".robine-artifact-sha256")

    cond do
      File.regular?(marker) and File.read(marker) == {:ok, artifact.digest} ->
        {:ok, target}

      File.exists?(target) ->
        {:error, :release_identity_conflict}

      true ->
        extract_release(artifact, target, config)
    end
  end

  defp extract_release(artifact, target, config) do
    temporary_root =
      Path.join(System.tmp_dir!(), "robine-deployment-#{Ecto.UUID.generate()}")

    outer = Path.join(temporary_root, "artifact.tar.gz")
    outer_directory = Path.join(temporary_root, "outer")
    staged_release = target <> ".staging-#{Ecto.UUID.generate()}"

    try do
      with :ok <- File.mkdir_p(outer_directory),
           :ok <- File.write(outer, artifact.body, [:binary, :exclusive]),
           :ok <- SafeTar.validate_workspace_archive(artifact.body),
           {:ok, _output} <- command(config, "tar", ["-xzf", outer, "-C", outer_directory]),
           {:ok, server_archive, manifest} <- release_payload(outer_directory),
           :ok <- Checksums.verify(manifest, Path.dirname(server_archive)),
           {:ok, inner} <- File.read(server_archive),
           :ok <- SafeTar.validate_workspace_archive(inner),
           :ok <- File.mkdir_p(staged_release),
           {:ok, _output} <-
             command(config, "tar", ["-xzf", server_archive, "-C", staged_release]),
           true <- File.regular?(Path.join(staged_release, "bin/robine")),
           :ok <-
             File.write(Path.join(staged_release, ".robine-artifact-sha256"), artifact.digest),
           :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.rename(staged_release, target) do
        {:ok, target}
      else
        false -> {:error, :invalid_server_release}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm_rf(temporary_root)
      if File.exists?(staged_release), do: File.rm_rf(staged_release)
    end
  end

  defp release_payload(directory) do
    archives = Path.wildcard(Path.join([directory, "**", "robine-server-*.tar.gz"]))
    manifests = Path.wildcard(Path.join([directory, "**", "SHA256SUMS"]))

    case {archives, manifests} do
      {[archive], manifests} ->
        case Enum.find(manifests, &(Path.dirname(&1) == Path.dirname(archive))) do
          nil -> {:error, :checksum_manifest_missing}
          manifest -> {:ok, archive, manifest}
        end

      _invalid ->
        {:error, :invalid_server_release_payload}
    end
  end

  defp environment(raw) when is_map(raw) do
    with {:ok, inserted_at, _offset} <- DateTime.from_iso8601(raw["inserted_at"]),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(raw["updated_at"]) do
      raw
      |> Map.put("inserted_at", inserted_at)
      |> Map.put("updated_at", updated_at)
      |> Environment.new()
    else
      _invalid -> {:error, :invalid_deployment_environment}
    end
  end

  defp environment(_raw), do: {:error, :invalid_deployment_environment}

  defp authorized_root(root, %{"deployment_roots" => roots}) when is_list(roots) do
    expanded = Path.expand(root)

    if Enum.any?(roots, &(Path.expand(&1) == expanded)),
      do: :ok,
      else: {:error, :deployment_root_not_allowed}
  end

  defp authorized_root(_root, _config), do: {:error, :deployment_root_not_allowed}

  defp command(config, executable, arguments) do
    case Map.get(config, :command_adapter) do
      nil ->
        case System.cmd(executable, arguments, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, status} ->
            {:error, {:command_failed, executable, status, String.slice(output, 0, 4096)}}
        end

      adapter ->
        adapter.command(executable, arguments, config)
    end
  rescue
    error -> {:error, {:command_unavailable, executable, error.__struct__}}
  end

  defp runtime_options(config, options) do
    case Map.get(config, :docker_adapter) do
      nil -> options
      adapter -> Keyword.put(options, :docker, &adapter.docker(&1, config))
    end
  end

  defp send_event(
         client,
         deployment_id,
         idempotency_token,
         sequence,
         status,
         reason,
         config
       ) do
    event = %{
      "deployment_id" => deployment_id,
      "idempotency_token" => idempotency_token,
      "message_id" => Ecto.UUID.generate(),
      "sequence" => sequence,
      "status" => Atom.to_string(status),
      "reason" => reason
    }

    case Map.get(config, :event_adapter) do
      nil -> RemoteClient.send_deployment_event(client, event)
      adapter -> adapter.send_deployment_event(client, event, config)
    end
  end

  defp identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(_value), do: {:error, :invalid_deployment_offer}

  defp kind("application"), do: {:ok, :application}
  defp kind("platform"), do: {:ok, :platform}
  defp kind("rollback"), do: {:ok, :application}
  defp kind(_kind), do: {:error, :invalid_deployment_offer}

  defp sha256(body),
    do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "deployment_failed"
end
