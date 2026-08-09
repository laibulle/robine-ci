defmodule Robine.ReleaseConfigurationTest do
  use ExUnit.Case, async: true

  test "the server release explicitly disables Erlang Distribution" do
    environment = File.read!("rel/env.sh.eex")

    assert environment =~ "export RELEASE_DISTRIBUTION=none"
    assert environment =~ "unset RELEASE_NODE"
    refute environment =~ "RELEASE_DISTRIBUTION=name"
    refute environment =~ "RELEASE_DISTRIBUTION=sname"
  end

  test "MVP application code does not call distributed Erlang primitives" do
    forbidden = ["Node.", ":net_kernel.", ":rpc.", ":erpc.", ":global.", ":pg2."]

    violations =
      for path <- Path.wildcard("lib/**/*.ex"),
          token <- forbidden,
          String.contains?(File.read!(path), token) do
        "#{path} contains #{token}"
      end

    assert violations == [], Enum.join(violations, "\n")
  end
end
