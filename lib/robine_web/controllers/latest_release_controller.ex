defmodule RobineWeb.LatestReleaseController do
  use RobineWeb, :controller
  alias Robine.Publications
  alias Robine.Runtime.Dependencies

  def show(conn, %{"slug" => slug, "filename" => filename}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    context =
      Dependencies.context(
        %{id: "public:latest", role: :viewer},
        request_correlation_id(conn)
      )

    case Publications.resolve_latest(%{public_slug: slug, filename: filename}, context) do
      {:ok, publication} ->
        redirect(conn, external: publication.public_url)

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  defp request_correlation_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [request_id | _rest] when request_id != "" -> request_id
      _missing -> Ecto.UUID.generate()
    end
  end
end
