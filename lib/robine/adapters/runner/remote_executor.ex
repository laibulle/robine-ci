defmodule Robine.Adapters.Runner.RemoteExecutor do
  @moduledoc "Executes one server-assigned job with the same Docker contract as the local runner."

  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Adapters.Execution.DockerRunner
  alias Robine.Adapters.Runner.RemoteClient
  alias Robine.Execution
  alias Robine.Execution.Dependencies, as: ExecutionDependencies
  alias Robine.ExecutionContext

  @spec run(map(), pid(), map()) :: :ok | {:error, term()}
  def run(offer, client, config) do
    with {:ok, identifiers} <- identifiers(offer),
         {:ok, source_path} <- materialize_source(offer["source_url"], config),
         {:ok, secrets} <- download_secrets(offer["secrets_url"], config) do
      try do
        execute(offer, identifiers, source_path, secrets, client, config)
      after
        cleanup_source(source_path)
      end
    else
      {:error, reason} ->
        _ = maybe_fail_preparation(offer, client)
        {:error, safe_error(reason)}
    end
  end

  defp execute(offer, identifiers, source_path, secrets, client, config) do
    raw = Map.put(offer["execution"], "resolved_secrets", secrets)
    context = execution_context(identifiers.attempt_id)

    case Execution.build_ci_specification(
           %{persisted: raw, source_path: source_path},
           context
         ) do
      {:ok, specification} ->
        run_specification(specification, identifiers, raw, offer, config, client, context)

      {:error, reason} ->
        _ = send_attempt(client, identifiers, 2, "failed", "system_failure")
        {:error, safe_error(reason)}
    end
  end

  defp run_specification(specification, identifiers, raw, offer, config, client, context) do
    with :ok <- send_attempt(client, identifiers, 2, "running") do
      cancellation = :atomics.new(1, signed: false)

      task =
        Task.async(fn ->
          Execution.run_job(
            %{
              specification: specification,
              on_output: &send_log(client, identifiers.attempt_id, &1),
              on_builtin: &handle_builtin(&1, raw, offer["builtins_url"], config),
              cancel_requested: fn -> :atomics.get(cancellation, 1) == 1 end
            },
            context
          )
        end)

      case await_execution(task, cancellation) do
        {:ok, result} ->
          send_result(client, identifiers, result)

        {:error, reason} ->
          _ = send_attempt(client, identifiers, 3, "failed", "system_failure")
          {:error, safe_error(reason)}
      end
    end
  end

  defp await_execution(%Task{ref: reference} = task, cancellation) do
    receive do
      :cancel_requested ->
        :atomics.put(cancellation, 1, 1)
        await_execution(task, cancellation)

      {^reference, result} ->
        Process.demonitor(reference, [:flush])
        result

      {:DOWN, ^reference, :process, _pid, reason} ->
        {:error, {:execution_task_exit, reason}}
    end
  end

  defp identifiers(%{
         "attempt_id" => attempt_id,
         "idempotency_token" => token,
         "execution" => execution
       })
       when is_binary(attempt_id) and is_binary(token) and is_map(execution) do
    {:ok, %{attempt_id: attempt_id, idempotency_token: token}}
  end

  defp identifiers(_offer), do: {:error, :invalid_job_offer}

  defp materialize_source(nil, _config), do: {:ok, nil}

  defp materialize_source(url, config) when is_binary(url) do
    case Map.get(config, :transfer_adapter) do
      nil ->
        with {:ok, archive} <- authenticated_get(url, config, "application/gzip"),
             {:ok, files} <- SafeTar.extract_source(archive),
             {:ok, directory} <- write_source(files) do
          {:ok, directory}
        end

      adapter ->
        adapter.download_source(url, config)
    end
  end

  defp download_secrets(url, config) when is_binary(url) do
    case Map.get(config, :transfer_adapter) do
      nil ->
        with {:ok, body} <- authenticated_get(url, config, "application/json"),
             {:ok, %{"secrets" => secrets}} <- Jason.decode(body),
             true <- is_map(secrets) and Enum.all?(secrets, &valid_secret?/1) do
          {:ok, secrets}
        else
          false -> {:error, :invalid_secret_response}
          {:error, reason} -> {:error, reason}
        end

      adapter ->
        adapter.download_secrets(url, config)
    end
  end

  defp authenticated_get(url, config, accept) do
    case authenticated_request(:get, url, config, nil, accept) do
      {:ok, 200, body} when is_binary(body) -> {:ok, body}
      {:ok, status, _body} -> {:error, {:transfer_http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticated_request(method, url, config, body, accept) do
    headers = [
      {"accept", accept},
      {"authorization", "Bearer #{config["credential"]}"},
      {"x-robine-runner-id", config["runner_id"]}
    ]

    case Map.get(config, :request_adapter) do
      nil -> request_with_req(method, url, headers, body)
      adapter -> adapter.request(method, url, headers, body, config)
    end
  end

  defp request_with_req(method, url, headers, body) do
    options =
      [
        method: method,
        url: url,
        headers: headers,
        body: body,
        receive_timeout: 60_000,
        decode_body: false
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Req.request(options) do
      {:ok, %{status: status, body: response_body}} -> {:ok, status, response_body}
      {:error, _exception} -> {:error, :transfer_unavailable}
    end
  end

  defp write_source(files) do
    directory = Path.join(System.tmp_dir!(), "robine-remote-source-#{Ecto.UUID.generate()}")

    with :ok <- File.mkdir(directory),
         :ok <- write_source_files(directory, files) do
      {:ok, directory}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:source_write, reason}}
    end
  end

  defp write_source_files(directory, files) do
    Enum.reduce_while(files, :ok, fn {relative, content}, :ok ->
      destination = Path.join(directory, relative)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, content, [:binary, :exclusive]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp send_log(client, attempt_id, event) do
    payload =
      event
      |> Map.put(:attempt_id, attempt_id)
      |> Map.new(fn {key, value} -> {to_string(key), normalize(value)} end)

    RemoteClient.send_log_event(client, payload)
  end

  defp send_result(client, identifiers, %{status: :succeeded}),
    do: send_attempt(client, identifiers, 3, "succeeded")

  defp send_result(client, identifiers, %{status: :failed, reason: reason}),
    do: send_attempt(client, identifiers, 3, "failed", to_string(reason))

  defp send_result(client, identifiers, %{status: :cancelled}),
    do: send_attempt(client, identifiers, 3, "cancelled", "cancelled")

  defp send_attempt(client, identifiers, sequence, status, reason \\ nil) do
    RemoteClient.send_attempt_event(client, %{
      "attempt_id" => identifiers.attempt_id,
      "idempotency_token" => identifiers.idempotency_token,
      "message_id" => Ecto.UUID.generate(),
      "sequence" => sequence,
      "status" => status,
      "reason" => reason
    })
  end

  defp maybe_fail_preparation(
         %{
           "attempt_id" => attempt_id,
           "idempotency_token" => token
         },
         client
       ) do
    send_attempt(
      client,
      %{attempt_id: attempt_id, idempotency_token: token},
      2,
      "failed",
      "system_failure"
    )
  end

  defp maybe_fail_preparation(_offer, _client), do: :ok

  defp execution_context(attempt_id) do
    ExecutionContext.new(
      %{id: "remote-runner", role: :administrator},
      "attempt:#{attempt_id}",
      %{execution: %ExecutionDependencies{runner: DockerRunner}}
    )
  end

  defp handle_builtin(
         %{phase: :restore, builtin: "cache/restore", options: %{"key" => key}},
         _raw,
         base_url,
         config
       )
       when is_binary(base_url) do
    download_builtin(base_url <> "/cache", %{key: key}, config, true)
  end

  defp handle_builtin(
         %{phase: :publish, builtin: "cache/save", options: %{"key" => key}, content: content},
         _raw,
         base_url,
         config
       )
       when is_binary(base_url) do
    upload_builtin(base_url <> "/cache", %{key: key}, content, config)
  end

  defp handle_builtin(
         %{
           phase: :publish,
           builtin: "artifacts/upload",
           options: %{"name" => name, "retention-days" => days},
           content: content
         },
         _raw,
         base_url,
         config
       )
       when is_binary(base_url) do
    upload_builtin(
      base_url <> "/artifacts",
      %{name: name, retention_days: days},
      content,
      config
    )
  end

  defp handle_builtin(
         %{
           phase: :restore,
           builtin: "artifacts/download",
           options: %{"name" => name, "from" => from_job}
         },
         _raw,
         base_url,
         config
       )
       when is_binary(base_url) do
    download_builtin(base_url <> "/artifacts", %{name: name, from: from_job}, config, false)
  end

  defp handle_builtin(event, _raw, _base_url, _config),
    do: {:error, {:unsupported_builtin_event, Map.drop(event, [:content])}}

  defp download_builtin(base_url, query, config, cache?) when is_binary(base_url) do
    url = base_url <> "?" <> URI.encode_query(query)

    case authenticated_request(:get, url, config, nil, "application/gzip") do
      {:ok, 200, body} -> {:ok, %{content: body}}
      {:ok, 204, _body} when cache? -> {:ok, :miss}
      {:ok, status, _body} -> {:error, {:transfer_http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_builtin(base_url, query, content, config)
       when is_binary(base_url) and is_binary(content) do
    url = base_url <> "?" <> URI.encode_query(query)

    case authenticated_request(:put, url, config, content, "application/json") do
      {:ok, status, _body} when status in [200, 201] -> {:ok, %{size: byte_size(content)}}
      {:ok, status, _body} -> {:error, {:transfer_http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_secret?({name, value}), do: is_binary(name) and is_binary(value)
  defp cleanup_source(nil), do: :ok
  defp cleanup_source(directory), do: File.rm_rf(directory)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value
  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error({tag, _detail}) when is_atom(tag), do: tag
  defp safe_error(_reason), do: :remote_execution_failed
end
