defmodule Robine.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Robine.Runtime.Dependencies.validate!()

    children = [
      RobineWeb.Telemetry,
      Robine.Repo,
      {Oban, Application.fetch_env!(:robine, Oban)},
      {DNSCluster, query: Application.get_env(:robine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Robine.PubSub},
      RobineWeb.LoginRateLimiter,
      Robine.Adapters.SourceControl.GitHubApiMonitor,
      Robine.Adapters.SourceControl.GitHubAppTokenCache,
      # Start a worker by calling: Robine.Worker.start_link(arg)
      # {Robine.Worker, arg},
      # Start to serve requests, typically the last entry
      RobineWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Robine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RobineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
