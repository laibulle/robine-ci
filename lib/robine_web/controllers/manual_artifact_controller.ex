defmodule RobineWeb.ManualArtifactController do
  use RobineWeb, :controller

  alias Robine.Storage

  @read_length 1_000_000

  def index(conn, %{"repository_id" => repository_id}) do
    case Storage.list_manual_artifacts(
           %{repository_id: repository_id},
           conn.assigns.execution_context
         ) do
      {:ok, artifacts} ->
        conn
        |> private_response()
        |> json(%{artifacts: Enum.map(artifacts, &serialize(&1, repository_id))})

      error ->
        respond_error(conn, error)
    end
  end

  def upload(conn, %{"repository_id" => repository_id, "name" => name} = params) do
    with {:ok, retention_days} <- positive_integer(Map.get(params, "retention_days", "30")),
         {:ok, content_type} <- content_type(conn),
         {:ok, path, conn} <- spool_body(conn) do
      try do
        result =
          Storage.upload_manual_artifact(
            %{
              repository_id: repository_id,
              name: name,
              content_type: content_type,
              content_stream: File.stream!(path, @read_length, []),
              retention_seconds: retention_days * 86_400
            },
            conn.assigns.execution_context
          )

        case result do
          {:ok, artifact} ->
            conn
            |> private_response()
            |> put_status(:created)
            |> json(serialize(artifact, repository_id))

          error ->
            respond_error(conn, error)
        end
      after
        Plug.Upload.delete(path)
      end
    else
      {:error, reason, conn} -> respond_error(conn, {:error, reason})
      {:error, reason} -> respond_error(conn, {:error, reason})
    end
  end

  def upload(conn, _params), do: respond_error(conn, {:error, {:invalid_artifact, :name}})

  def download(conn, %{"repository_id" => repository_id, "artifact_id" => artifact_id}) do
    case Storage.download_manual_artifact(
           %{repository_id: repository_id, artifact_id: artifact_id},
           conn.assigns.execution_context
         ) do
      {:ok, artifact} ->
        conn
        |> private_response()
        |> put_resp_content_type(artifact.content_type)
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{safe_filename(artifact.name)}")
        )
        |> put_resp_header("x-content-sha256", artifact.digest)
        |> send_resp(:ok, artifact.content)

      error ->
        respond_error(conn, error)
    end
  end

  defp spool_body(conn) do
    max_bytes = Application.fetch_env!(:robine, :storage_max_object_bytes)

    with {:ok, path} <- Plug.Upload.random_file("robine-manual-artifact"),
         {:ok, result} <-
           File.open(path, [:write, :binary], fn file ->
             read_body(conn, file, 0, max_bytes)
           end) do
      case result do
        {:ok, conn} ->
          {:ok, path, conn}

        {:error, reason, conn} ->
          Plug.Upload.delete(path)
          {:error, reason, conn}
      end
    else
      {:error, reason} -> {:error, {:upload_spool, reason}, conn}
    end
  end

  defp read_body(conn, file, size, max_bytes) do
    remaining = max_bytes - size

    case Plug.Conn.read_body(conn,
           length: remaining + 1,
           read_length: min(@read_length, remaining + 1)
         ) do
      {:ok, body, conn} when size + byte_size(body) <= max_bytes ->
        :ok = IO.binwrite(file, body)
        {:ok, conn}

      {:more, body, conn} when size + byte_size(body) <= max_bytes ->
        :ok = IO.binwrite(file, body)
        read_body(conn, file, size + byte_size(body), max_bytes)

      {:ok, _body, conn} ->
        {:error, :payload_too_large, conn}

      {:more, _body, conn} ->
        {:error, :payload_too_large, conn}

      {:error, reason} ->
        {:error, {:upload_read, reason}, conn}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] when value != "" -> {:ok, value}
      [] -> {:ok, "application/octet-stream"}
      _invalid -> {:error, {:invalid_artifact, :content_type}}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 and integer <= 365 -> {:ok, integer}
      _invalid -> {:error, {:invalid_artifact, :retention}}
    end
  end

  defp positive_integer(_value), do: {:error, {:invalid_artifact, :retention}}

  defp serialize(artifact, repository_id) do
    %{
      id: artifact.id,
      source: artifact.source,
      uploaded_by_id: artifact.uploaded_by_id,
      name: artifact.name,
      content_type: artifact.content_type,
      digest: artifact.digest,
      size: artifact.size,
      created_at: DateTime.to_iso8601(artifact.created_at),
      expires_at: DateTime.to_iso8601(artifact.expires_at),
      download_url: "/api/v1/repositories/#{repository_id}/artifacts/#{artifact.id}"
    }
  end

  defp respond_error(conn, {:error, :forbidden}) do
    conn |> private_response() |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

  defp respond_error(conn, {:error, reason})
       when reason in [:repository_not_found, :not_found, :expired] do
    conn |> private_response() |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  defp respond_error(conn, {:error, reason})
       when reason in [:payload_too_large, :object_too_large] do
    conn
    |> private_response()
    |> put_status(:request_entity_too_large)
    |> json(%{error: "payload_too_large"})
  end

  defp respond_error(conn, {:error, {:quota_exceeded, scope, limit}}) do
    conn
    |> private_response()
    |> put_status(:unprocessable_entity)
    |> json(%{error: "quota_exceeded", scope: scope, limit: limit})
  end

  defp respond_error(conn, {:error, {:invalid_artifact, field}}) do
    conn
    |> private_response()
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_artifact", field: field})
  end

  defp respond_error(conn, {:error, _reason}) do
    conn
    |> private_response()
    |> put_status(:service_unavailable)
    |> json(%{error: "artifact_unavailable"})
  end

  defp private_response(conn), do: put_resp_header(conn, "cache-control", "private, no-store")
  defp safe_filename(name), do: String.replace(name, ~r/[^a-zA-Z0-9._-]/, "-")
end
