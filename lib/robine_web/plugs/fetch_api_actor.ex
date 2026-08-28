defmodule RobineWeb.Plugs.FetchApiActor do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Robine.Identities
  alias Robine.Runtime.Dependencies

  def init(options), do: options

  def call(conn, _options) do
    with {:ok, token} <- bearer(conn),
         context <-
           Dependencies.context(
             %{id: "api:anonymous", role: :viewer},
             conn.assigns[:request_id] || "api"
           ),
         {:ok, actor} <- Identities.resolve_session(%{token: token}, context) do
      conn
      |> assign(:current_actor, actor)
      |> assign(
        :execution_context,
        Dependencies.context(actor, conn.assigns[:request_id] || "api")
      )
    else
      _invalid ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _invalid -> {:error, :missing_bearer}
    end
  end
end
