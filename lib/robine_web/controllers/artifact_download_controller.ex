defmodule RobineWeb.ArtifactDownloadController do
  use RobineWeb, :controller

  alias Robine.Runtime.Dependencies
  alias Robine.Storage

  def download(conn, %{"id" => repository_id, "artifact_id" => artifact_id}) do
    with %{id: _id} = actor <- conn.assigns[:current_actor],
         context <-
           Dependencies.context(
             actor,
             conn.assigns[:request_id] || "artifact-download"
           ),
         {:ok, artifact} <-
           Storage.download_artifact(
             %{repository_id: repository_id, artifact_id: artifact_id},
             context
           ) do
      conn
      |> put_resp_content_type(artifact.content_type)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{safe_filename(artifact.name)}")
      )
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-sha256", artifact.digest)
      |> send_resp(:ok, artifact.content)
    else
      nil ->
        redirect(conn, to: ~p"/sign-in")

      {:error, reason} when reason in [:not_found, :expired] ->
        send_resp(conn, :not_found, "Artifact not found or expired")

      {:error, :forbidden} ->
        send_resp(conn, :forbidden, "Forbidden")

      {:error, _reason} ->
        send_resp(conn, :service_unavailable, "Artifact unavailable")
    end
  end

  defp safe_filename(name), do: String.replace(name, ~r/[^a-zA-Z0-9._-]/, "-")
end
