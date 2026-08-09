defmodule RobineWeb.RunnerAttemptController do
  use RobineWeb, :controller

  alias Robine.{Pipelines, Repositories, Runners, Secrets, Storage, Transfers}
  alias Robine.Runtime.Dependencies

  @max_upload_bytes 100 * 1024 * 1024

  def source(conn, %{"attempt_id" => attempt_id}) do
    with {:ok, raw, _runner_context, system_context} <- authorized_execution(conn, attempt_id),
         true <- checkout_required?(raw),
         {:ok, source} <-
           Repositories.fetch_source(
             %{repository_id: raw["repository_id"], commit_sha: raw["commit_sha"]},
             system_context
           ),
         {:ok, archive} <-
           Transfers.create_source_archive(%{files: source.files}, system_context) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_binary_chunks(archive)
    else
      false ->
        conn |> put_status(:not_found) |> json(%{error: "source not required"})

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, :forbidden} ->
        unauthorized(conn)

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "source unavailable"})
    end
  end

  def secrets(conn, %{"attempt_id" => attempt_id}) do
    with {:ok, raw, _runner_context, system_context} <- authorized_execution(conn, attempt_id),
         {:ok, values} <- resolve_secret_values(raw, system_context) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{secrets: values})
    else
      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, :forbidden} ->
        unauthorized(conn)

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "secrets unavailable"})
    end
  end

  def restore_cache(conn, %{"attempt_id" => attempt_id, "key" => key}) do
    with {:ok, raw, _runner_context, system_context} <- authorized_execution(conn, attempt_id),
         {:ok, download} <-
           Storage.restore_cache(%{repository_id: raw["repository_id"], key: key}, system_context) do
      send_transfer_download(conn, download)
    else
      error -> transfer_error(conn, error)
    end
  end

  def restore_cache(conn, _params), do: invalid_transfer(conn)

  def save_cache(conn, %{"attempt_id" => attempt_id, "key" => key}) do
    with {:ok, raw, _runner_context, system_context} <- authorized_execution(conn, attempt_id),
         {:ok, chunks, conn} <- read_upload(conn),
         {:ok, metadata} <-
           Storage.save_cache(
             %{repository_id: raw["repository_id"], key: key, content_stream: chunks},
             system_context
           ) do
      conn |> put_status(:created) |> json(%{digest: metadata.digest, size: metadata.size})
    else
      error -> transfer_error(conn, error)
    end
  end

  def save_cache(conn, _params), do: invalid_transfer(conn)

  def download_artifact(
        conn,
        %{"attempt_id" => attempt_id, "name" => name, "from" => from_job}
      ) do
    with {:ok, raw, _runner_context, system_context} <- authorized_execution(conn, attempt_id),
         {:ok, download} <-
           Storage.download_dependency_artifact(
             %{
               pipeline_id: raw["pipeline_id"],
               from_job: from_job,
               name: name,
               needs: raw["needs"]
             },
             system_context
           ) do
      send_transfer_download(conn, download)
    else
      error -> transfer_error(conn, error)
    end
  end

  def download_artifact(conn, _params), do: invalid_transfer(conn)

  def upload_artifact(
        conn,
        %{"attempt_id" => attempt_id, "name" => name, "retention_days" => retention_days}
      ) do
    with {:ok, days} <- positive_integer(retention_days),
         {:ok, raw, _runner_context, system_context} <- authorized_execution(conn, attempt_id),
         {:ok, chunks, conn} <- read_upload(conn),
         {:ok, metadata} <-
           Storage.upload_artifact(
             %{
               repository_id: raw["repository_id"],
               attempt_id: attempt_id,
               name: name,
               content_stream: chunks,
               retention_seconds: days * 86_400
             },
             system_context
           ) do
      conn
      |> put_status(:created)
      |> json(%{id: metadata.id, digest: metadata.digest, size: metadata.size})
    else
      error -> transfer_error(conn, error)
    end
  end

  def upload_artifact(conn, _params), do: invalid_transfer(conn)

  defp authorized_execution(conn, attempt_id) do
    with {:ok, runner_id} <- request_header(conn, "x-robine-runner-id"),
         {:ok, credential} <- bearer(conn),
         correlation_id = List.first(get_req_header(conn, "x-request-id")) || Ecto.UUID.generate(),
         anonymous_context =
           Dependencies.context(%{id: "anonymous:runner-api", role: :runner}, correlation_id),
         {:ok, identity} <-
           Runners.authenticate(
             %{runner_id: runner_id, credential: credential},
             anonymous_context
           ),
         runner_context =
           Dependencies.context(%{id: identity.runner_id, role: :runner}, correlation_id),
         {:ok, raw} <-
           Pipelines.remote_job_execution(%{attempt_id: attempt_id}, runner_context) do
      system_context =
        Dependencies.context(
          %{id: "system:remote-transfer", role: :administrator},
          correlation_id
        )

      {:ok, raw, runner_context, system_context}
    else
      _failure -> {:error, :unauthorized}
    end
  end

  defp resolve_secret_values(%{"secret_names" => []}, _context), do: {:ok, %{}}

  defp resolve_secret_values(%{"secret_names" => names} = raw, context) when is_list(names) do
    Secrets.resolve_secrets(%{repository_id: raw["repository_id"], names: names}, context)
  end

  defp resolve_secret_values(_raw, _context), do: {:ok, %{}}

  defp checkout_required?(%{"steps" => steps}) when is_list(steps) do
    Enum.any?(steps, fn
      %{"kind" => kind, "value" => "checkout"} when kind in ["builtin", :builtin] -> true
      _step -> false
    end)
  end

  defp checkout_required?(_raw), do: false

  defp bearer(conn) do
    case request_header(conn, "authorization") do
      {:ok, "Bearer " <> credential} when credential != "" -> {:ok, credential}
      _invalid -> {:error, :missing_credential}
    end
  end

  defp request_header(conn, name) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _missing_or_repeated -> {:error, :missing_header}
    end
  end

  defp read_upload(conn), do: read_upload(conn, [], 0)

  defp read_upload(conn, chunks, size) do
    remaining = @max_upload_bytes - size

    case Plug.Conn.read_body(conn,
           length: remaining + 1,
           read_length: min(1_000_000, remaining + 1)
         ) do
      {:ok, body, conn} when size + byte_size(body) <= @max_upload_bytes ->
        {:ok, Enum.reverse([body | chunks]), conn}

      {:more, body, conn} when size + byte_size(body) <= @max_upload_bytes ->
        read_upload(conn, [body | chunks], size + byte_size(body))

      {:ok, _oversized, conn} ->
        {:error, :payload_too_large, conn}

      {:more, _oversized, conn} ->
        {:error, :payload_too_large, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_transfer_download(conn, :miss), do: send_resp(conn, :no_content, "")

  defp send_transfer_download(conn, %{content: content, digest: digest})
       when is_binary(content) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-sha256", digest)
    |> send_binary_chunks(content)
  end

  defp send_binary_chunks(conn, content) do
    conn = conn |> put_resp_content_type("application/gzip") |> send_chunked(:ok)

    content
    |> binary_chunks([])
    |> Enum.reduce_while(conn, fn binary, conn ->
      case chunk(conn, binary) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp binary_chunks("", chunks), do: Enum.reverse(chunks)

  defp binary_chunks(binary, chunks) when byte_size(binary) <= 64_000,
    do: Enum.reverse([binary | chunks])

  defp binary_chunks(<<chunk::binary-size(64_000), rest::binary>>, chunks),
    do: binary_chunks(rest, [chunk | chunks])

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _invalid -> {:error, :invalid_retention}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_retention}

  defp transfer_error(_conn, {:error, :payload_too_large, conn}),
    do: conn |> put_status(:payload_too_large) |> json(%{error: "payload too large"})

  defp transfer_error(conn, {:error, reason}) when reason in [:unauthorized, :forbidden],
    do: unauthorized(conn)

  defp transfer_error(conn, {:error, reason})
       when reason in [:undeclared_dependency, :artifact_expired],
       do: conn |> put_status(:not_found) |> json(%{error: "content unavailable"})

  defp transfer_error(conn, {:error, {kind, _field}})
       when kind in [:invalid_cache, :invalid_artifact],
       do: invalid_transfer(conn)

  defp transfer_error(conn, {:error, :invalid_dependency_artifact_request}),
    do: invalid_transfer(conn)

  defp transfer_error(conn, _error),
    do: conn |> put_status(:service_unavailable) |> json(%{error: "transfer unavailable"})

  defp invalid_transfer(conn),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid transfer"})

  defp unauthorized(conn),
    do: conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
end
