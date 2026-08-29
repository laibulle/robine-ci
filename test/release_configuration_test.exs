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

  test "the cross-platform installers are transparent and verify GitHub release digests" do
    installer_path = "priv/static/install/rbe.sh"
    installer = File.read!(installer_path)
    windows_installer = File.read!("priv/static/install/rbe.ps1")

    assert {_, 0} = System.cmd("bash", ["-n", installer_path], stderr_to_stdout: true)
    assert "install" in RobineWeb.static_paths()
    assert installer =~ "api.github.com/repos/${repository}/releases/latest"
    assert installer =~ "github.com/${repository}/releases/download/${tag}/${asset_name}"
    assert installer =~ "shasum -a 256"
    assert installer =~ "sha256sum"
    assert installer =~ ~s|Darwin)|
    assert installer =~ ~s|Linux)|
    assert installer =~ ~s|asset_name="robine-runner-${asset_platform}-multiarch.tar.gz"|
    assert installer =~ "mv -f \"${temporary_destination}\" \"${install_dir}/rbe\""
    assert installer =~ "install_arguments=(install)"
    assert installer =~ "RBE_CONFIG_PATH"
    assert installer =~ "RBE_SERVER_URL"
    assert installer =~ "RBE_SKIP_SERVICE_INSTALL"
    refute installer =~ "launchctl bootstrap"
    refute installer =~ "base64"
    refute installer =~ "eval"
    refute installer =~ "sudo"

    assert windows_installer =~ "$env:PROCESSOR_ARCHITECTURE"
    assert windows_installer =~ "robine-runner-windows-multiarch.tar.gz"
    assert windows_installer =~ "Get-FileHash -Algorithm SHA256"
    assert windows_installer =~ "Move-Item -LiteralPath $TemporaryDestination"
    assert windows_installer =~ "Windows service installation is not available yet"
    refute windows_installer =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN='"
    refute windows_installer =~ "Start-Service"
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

  test "the production bundle isolates Docker in the bundled Go runner" do
    compose = YamlElixir.read_from_file!("rel/overlays/compose.yaml")
    server = get_in(compose, ["services", "server"])
    runner = get_in(compose, ["services", "runner"])
    server_volumes = server["volumes"]
    runner_volumes = runner["volumes"]
    entrypoint = File.read!("rel/overlays/bin/start-bundled-runner")
    release_task = File.read!("lib/mix/tasks/robine.server_release.ex")

    refute Enum.any?(server_volumes, &String.contains?(&1, "docker.sock"))
    assert Enum.any?(runner_volumes, &String.contains?(&1, "docker.sock"))

    assert Map.keys(runner["environment"])
           |> Enum.all?(&(not String.contains?(&1, ["TOKEN", "CREDENTIAL", "SECRET"])))

    refute Map.has_key?(runner, "env_file")
    assert runner["command"] == ["/opt/robine/bin/start-bundled-runner"]
    assert entrypoint =~ "ROBINE_BUNDLED_RUNNER_BINARY:-/opt/robine/bin/rbe"
    assert entrypoint =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN=$(cat \"$token_path\")"
    assert entrypoint =~ "--executor docker"
    assert entrypoint =~ ~s|if [ "$runner_status" -eq 78 ]|
    assert entrypoint =~ ~s|rm -f "$config_path" "$marker_path"|
    refute entrypoint =~ "--token"
    assert release_task =~ ~s({"CGO_ENABLED", "0"})
    assert release_task =~ ~s("-buildvcs=false")
    assert release_task =~ ~s|Path.join([release_root, "bin", "rbe"])|
  end
end
