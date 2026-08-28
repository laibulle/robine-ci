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

  test "the standalone runner builds in a server-secret-free environment" do
    task = File.read!("lib/mix/tasks/robine.runner_release.ex")
    runner_config = File.read!("config/runner.exs")

    assert task =~ ~s({"MIX_ENV", "runner"})
    assert runner_config =~ "standalone runner is an outbound CLI process"
    assert runner_config =~ "bootstrap secrets"
    refute runner_config =~ "DATABASE_URL"
    refute runner_config =~ "ROBINE_BOOTSTRAP_TOKEN"
    refute runner_config =~ "SECRET_KEY_BASE"
  end

  test "the macOS launch agent invokes the self-contained runner directly" do
    launchd = File.read!("docs/launchd/com.robine.runner.plist")

    assert launchd =~ "__ROBINE_RUNNER_HOME__/bin/robine-runner"
    assert launchd =~ "<string>start</string>"
    refute launchd =~ "mise"
    refute launchd =~ ".escript"
  end
end
