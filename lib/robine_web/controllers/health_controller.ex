defmodule RobineWeb.HealthController do
  use RobineWeb, :controller

  alias Robine.Operations
  alias Robine.Runtime.Dependencies

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    context =
      Dependencies.context(
        %{id: "system:health", role: :administrator},
        Ecto.UUID.generate()
      )

    case Operations.health(%{}, context) do
      {:ok, %{status: :ready} = health} ->
        json(conn, public_projection(health))

      {:ok, health} ->
        conn
        |> put_status(:service_unavailable)
        |> json(public_projection(health))

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "not_ready"})
    end
  end

  defp public_projection(health) do
    %{
      status: to_string(health.status),
      checked_at: DateTime.to_iso8601(health.checked_at)
    }
  end
end
