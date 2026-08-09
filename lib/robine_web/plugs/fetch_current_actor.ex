defmodule RobineWeb.Plugs.FetchCurrentActor do
  @moduledoc false
  import Plug.Conn
  alias Robine.Identities
  alias Robine.Runtime.Dependencies

  def init(options), do: options

  def call(conn, _options) do
    with token when is_binary(token) <- get_session(conn, :session_token),
         context <-
           Dependencies.context(
             %{id: "anonymous", role: :viewer},
             conn.assigns[:request_id] || "web"
           ),
         {:ok, actor} <- Identities.resolve_session(%{token: token}, context) do
      assign(conn, :current_actor, actor)
    else
      _ -> assign(conn, :current_actor, nil)
    end
  end
end
