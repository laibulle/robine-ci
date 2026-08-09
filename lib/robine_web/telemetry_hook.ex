defmodule RobineWeb.TelemetryHook do
  @moduledoc false
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    :telemetry.execute(
      [:robine, :web, :liveview, :connection],
      %{count: 1},
      %{outcome: if(connected?(socket), do: :connected, else: :server_render)}
    )

    {:cont, socket}
  end
end
