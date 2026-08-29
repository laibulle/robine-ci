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

    assert launchd =~ "__ROBINE_RUNNER_HOME__/.local/bin/rbe"
    assert launchd =~ "__ROBINE_RUNNER_CONFIG__"
    assert launchd =~ "<string>start</string>"
    refute launchd =~ "mise"
    refute launchd =~ ".escript"
  end

  test "the macOS installer is transparent and verifies the GitHub release digest" do
    installer_path = "priv/static/install/rbe.sh"
    installer = File.read!(installer_path)

    assert {_, 0} = System.cmd("bash", ["-n", installer_path], stderr_to_stdout: true)
    assert "install" in RobineWeb.static_paths()
    assert installer =~ "api.github.com/repos/${repository}/releases/latest"
    assert installer =~ "github.com/${repository}/releases/download/${tag}/${asset_name}"
    assert installer =~ "shasum -a 256"
    assert installer =~ "mv -f \"${temporary_destination}\" \"${install_dir}/rbe\""
    assert installer =~ "install_arguments=(install)"
    assert installer =~ "RBE_CONFIG_PATH"
    assert installer =~ "RBE_SERVER_URL"
    assert installer =~ "RBE_SKIP_SERVICE_INSTALL"
    refute installer =~ "launchctl bootstrap"
    refute installer =~ "base64"
    refute installer =~ "eval"
    refute installer =~ "sudo"
  end

  test "CI and release builds pin the supported OTP toolchain" do
    tool_versions = File.read!(".tool-versions")
    ci = File.read!(".robine-ci/workflows/ci.yml")
    release = File.read!(".robine-ci/workflows/release.yml")
    image = "hexpm/elixir@sha256:2431278a45d8aa9e019202ee73fc50eed21df9b456c4b72ed09b37550b04069b"

    assert tool_versions =~ "erlang 29.0.5"
    assert tool_versions =~ "elixir 1.20.3-otp-29"
    assert ci =~ "image: #{image}"
    assert release =~ "image: #{image}"
  end
end
