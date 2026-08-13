defmodule Robine.Runtime do
  @moduledoc "Public supervision entry point for standalone and embedded backend runtimes."

  use Supervisor

  @profiles [:standalone, :embedded]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    profile = Keyword.get(options, :profile, configured_profile())

    %{
      id: Keyword.get(options, :id, __MODULE__),
      start: {__MODULE__, :start_link, [Keyword.put(options, :profile, profile)]},
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    profile = Keyword.get(options, :profile, configured_profile())
    validate_profile!(profile)

    Supervisor.start_link(__MODULE__, Keyword.put(options, :profile, profile),
      name: Keyword.get(options, :name, Robine.Supervisor)
    )
  end

  @impl true
  def init(options) do
    profile = Keyword.fetch!(options, :profile)
    :ok = Robine.Runtime.Dependencies.validate!(profile)
    Supervisor.init(children(profile), strategy: :one_for_one)
  end

  @doc false
  def children(profile) when profile in @profiles,
    do: engine_children(profile) ++ delivery_children(profile)

  @spec configured_profile() :: :standalone | :embedded
  def configured_profile, do: Application.get_env(:robine, :runtime_profile, :standalone)

  @spec standalone?() :: boolean()
  def standalone?, do: configured_profile() == :standalone

  @doc "Configures Robine from a host repository before embedded supervision starts."
  @spec configure_embedded!(keyword()) :: :ok
  def configure_embedded!(options), do: Robine.Runtime.EmbeddedConfiguration.configure!(options)

  defp engine_children(profile) do
    [
      Robine.Repo,
      {Robine.Adapters.Persistence.Postgres.TenantGuard, profile: profile},
      Robine.Adapters.Storage.BackendGuard,
      {Oban, Application.fetch_env!(:robine, Oban)},
      {DNSCluster, query: Application.get_env(:robine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Robine.PubSub},
      Robine.Adapters.SourceControl.GitHubApiMonitor,
      Robine.Adapters.SourceControl.GitHubAppTokenCache
    ]
  end

  defp delivery_children(:embedded), do: []

  defp delivery_children(:standalone),
    do: [RobineWeb.Telemetry, RobineWeb.LoginRateLimiter, RobineWeb.Endpoint]

  defp validate_profile!(profile) when profile in @profiles, do: :ok

  defp validate_profile!(profile) do
    raise ArgumentError,
          "unsupported Robine runtime profile #{inspect(profile)}; expected :standalone or :embedded"
  end
end
