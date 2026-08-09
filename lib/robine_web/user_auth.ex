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
      _ ->
        authorization_reject(:anonymous, :authenticated)
        {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  def on_mount(:require_maintainer, _params, _session, socket) do
    case socket.assigns[:current_actor] do
      %{role: role} when role in [:administrator, :maintainer] ->
        {:cont, socket}

      %{role: role} ->
        authorization_reject(role, :maintainer)
        {:halt, redirect(socket, to: "/pipelines")}

      _ ->
        authorization_reject(:anonymous, :maintainer)
        {:halt, redirect(socket, to: "/pipelines")}
    end
  end

  def on_mount(:require_administrator, _params, _session, socket) do
    case socket.assigns[:current_actor] do
      %{role: :administrator} ->
        {:cont, socket}

      %{role: role} ->
        authorization_reject(role, :administrator)
        {:halt, redirect(socket, to: "/pipelines")}

      _ ->
        authorization_reject(:anonymous, :administrator)
        {:halt, redirect(socket, to: "/pipelines")}
    end
  end

  defp authorization_reject(role, surface) do
    :telemetry.execute(
      [:robine, :identity, :authorization, :reject],
      %{count: 1},
      %{role: role, surface: surface}
    )
  end
end
