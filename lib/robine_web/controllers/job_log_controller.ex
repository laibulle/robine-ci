defmodule RobineWeb.JobLogController do
  use RobineWeb, :controller

  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  @page_size 200
  @streams ~w(stdout stderr)

  def download(conn, %{"id" => pipeline_id, "job_id" => job_id} = params) do
    stream = requested_stream(params)

    with %{id: _id} = actor <- conn.assigns[:current_actor],
         context <- Dependencies.context(actor, conn.assigns[:request_id] || "log-download"),
         {:ok, %{pipeline: %{id: ^pipeline_id}, job: job}} <-
           Pipelines.job_detail(%{job_id: job_id}, context),
         {:ok, conn} <- start_download(conn, job, stream) do
      stream_pages(conn, job_id, context, stream, 0)
    else
      nil -> redirect(conn, to: ~p"/sign-in")
      {:error, :not_found} -> send_resp(conn, :not_found, "Log file not found")
      {:error, :forbidden} -> send_resp(conn, :forbidden, "Forbidden")
      {:error, _reason} -> send_resp(conn, :service_unavailable, "Log file unavailable")
    end
  end

  defp start_download(conn, job, stream) do
    suffix = if stream == "all", do: "combined", else: stream
    filename = "#{job.job_key}-attempt-logs-#{suffix}.log"

    conn =
      conn
      |> put_resp_content_type("text/plain", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> put_resp_header("cache-control", "private, no-store")
      |> send_chunked(:ok)

    {:ok, conn}
  end

  defp stream_pages(conn, job_id, context, stream, cursor) do
    case Pipelines.list_job_logs(%{job_id: job_id, after: cursor, limit: @page_size}, context) do
      {:ok, %{chunks: chunks, next_cursor: next_cursor, has_more: has_more}} ->
        body =
          chunks
          |> Enum.filter(&(stream == "all" or &1.stream == stream))
          |> Enum.map_join(&format_chunk(&1, stream))

        with {:ok, conn} <- maybe_chunk(conn, body) do
          if has_more,
            do: stream_pages(conn, job_id, context, stream, next_cursor),
            else: conn
        end

      {:error, _reason} ->
        conn
    end
  end

  defp maybe_chunk(conn, ""), do: {:ok, conn}
  defp maybe_chunk(conn, body), do: chunk(conn, body)

  defp format_chunk(log_chunk, "all"), do: "[#{log_chunk.stream}] #{log_chunk.content}"
  defp format_chunk(log_chunk, _stream), do: log_chunk.content

  defp requested_stream(%{"stream" => stream}) when stream in @streams, do: stream
  defp requested_stream(_params), do: "all"
end
