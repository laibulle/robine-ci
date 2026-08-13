defmodule Robine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Robine.Runtime.start_link(profile: Robine.Runtime.configured_profile())
  end

  @impl true
  def config_change(changed, _new, removed) do
    if Robine.Runtime.standalone?(), do: RobineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
