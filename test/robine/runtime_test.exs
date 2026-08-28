defmodule Robine.RuntimeTest do
  use ExUnit.Case, async: false

  alias Robine.Runtime
  alias Robine.Runtime.Dependencies
  alias Robine.Runtime.Metadata

  test "embedded runtime exports engine children without standalone web delivery" do
    children = Runtime.children(:embedded)

    assert Robine.Repo in children
    assert {Robine.Adapters.Persistence.Postgres.TenantGuard, profile: :embedded} in children
    assert {Phoenix.PubSub, name: Robine.PubSub} in children
    refute RobineWeb.Endpoint in children
    refute RobineWeb.Telemetry in children
    refute RobineWeb.LoginRateLimiter in children
  end

  test "standalone runtime retains its endpoint and identity delivery" do
    children = Runtime.children(:standalone)

    assert RobineWeb.Endpoint in children
    assert RobineWeb.Telemetry in children
    assert RobineWeb.LoginRateLimiter in children
  end

  test "publishes package and migration metadata" do
    assert Metadata.version() == "0.3.0-alpha6"
    assert Metadata.default_prefix() == "robine_ci"
    assert File.dir?(Metadata.migrations_path())
  end

  test "rejects unsupported profiles before starting children" do
    assert_raise ArgumentError, ~r/unsupported Robine runtime profile/, fn ->
      Runtime.start_link(profile: :invalid, name: :invalid_robine_runtime)
    end
  end

  test "embedded dependency validation does not require standalone identity configuration" do
    identity_keys = [:oidc_adapter, :oidc_config, :bootstrap_token_hash, :bootstrap_expires_at]
    previous = Map.new(identity_keys, &{&1, Application.fetch_env(:robine, &1)})

    Enum.each(identity_keys, &Application.delete_env(:robine, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :error} -> Application.delete_env(:robine, key)
        {key, {:ok, value}} -> Application.put_env(:robine, key, value)
      end)
    end)

    assert :ok = Dependencies.validate!(:embedded)
  end
end
