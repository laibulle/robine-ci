defmodule Robine.RuntimeTest do
  use ExUnit.Case, async: true

  alias Robine.Runtime
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
    assert Metadata.version() == "0.2.0"
    assert Metadata.default_prefix() == "robine_ci"
    assert File.dir?(Metadata.migrations_path())
  end

  test "rejects unsupported profiles before starting children" do
    assert_raise ArgumentError, ~r/unsupported Robine runtime profile/, fn ->
      Runtime.start_link(profile: :invalid, name: :invalid_robine_runtime)
    end
  end
end
