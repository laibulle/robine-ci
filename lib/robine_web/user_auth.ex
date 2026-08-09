defmodule RobineWeb.UserAuth do
  @moduledoc false
  import Phoenix.LiveView

  alias Robine.Identities
  alias Robine.Runtime.Dependencies

  def on_mount(:require_authenticated, _params, session, socket) do
    with token when is_binary(token) <- session["session_token"],
         context <- Dependencies.context(%{id: "anonymous", role: :viewer}, "live-session"),
         {:ok, actor} <- Identities.resolve_session(%{token: token}, context) do
      {:cont,
       Phoenix.Component.assign(socket,
         current_actor: actor,
         execution_context: Dependencies.context(actor, "live:#{actor.id}")
       )}
    else
      _ -> {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  def on_mount(:require_maintainer, _params, _session, socket) do
    case socket.assigns[:current_actor] do
      %{role: role} when role in [:administrator, :maintainer] -> {:cont, socket}
      _ -> {:halt, redirect(socket, to: "/pipelines")}
    end
  end

  def on_mount(:require_administrator, _params, _session, socket) do
    case socket.assigns[:current_actor] do
      %{role: :administrator} -> {:cont, socket}
      _ -> {:halt, redirect(socket, to: "/pipelines")}
    end
  end
end
