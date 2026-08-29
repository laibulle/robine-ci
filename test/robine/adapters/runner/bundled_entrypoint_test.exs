defmodule Robine.Adapters.Runner.BundledEntrypointTest do
  use ExUnit.Case, async: true

  @entrypoint Path.expand("../../../../rel/overlays/bin/start-bundled-runner", __DIR__)

  test "enrolls from the private handoff without exposing the token" do
    root = Path.join(System.tmp_dir!(), "robine-entrypoint-#{System.unique_integer([:positive])}")
    bootstrap = Path.join(root, "bootstrap")
    config = Path.join(root, "state/config.json")
    fake = Path.join(root, "fake-rbe")
    File.mkdir_p!(bootstrap)
    File.write!(Path.join(bootstrap, "enrollment-token"), "rbe_private_token", [:binary])
    File.chmod!(Path.join(bootstrap, "enrollment-token"), 0o600)

    File.write!(fake, """
    #!/bin/sh
    set -eu
    case "$1" in
      enroll)
        test "$ROBINE_RUNNER_ENROLLMENT_TOKEN" = "rbe_private_token"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--config" ]; then shift; config_path=$1; fi
          shift
        done
        printf '{"configured":true}\\n' >"$config_path"
        chmod 600 "$config_path"
        ;;
      start) exit 0 ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(fake, 0o700)

    {output, status} =
      System.cmd("/bin/sh", [@entrypoint],
        stderr_to_stdout: true,
        env: [
          {"ROBINE_BUNDLED_RUNNER_BINARY", fake},
          {"ROBINE_BUNDLED_RUNNER_CONFIG", config},
          {"ROBINE_BUNDLED_RUNNER_BOOTSTRAP_DIRECTORY", bootstrap},
          {"ROBINE_PUBLIC_URL", "https://ci.example.test"}
        ]
      )

    assert status == 0
    refute output =~ "rbe_private_token"
    assert File.stat!(config).mode |> Bitwise.band(0o777) == 0o600
    assert File.read!(Path.join(bootstrap, "configured")) == "configured\n"
    refute File.exists?(Path.join(bootstrap, "enrollment-token"))

    on_exit(fn -> File.rm_rf(root) end)
  end

  test "clears only an authentication-rejected configuration for rebootstrap" do
    root =
      Path.join(System.tmp_dir!(), "robine-rebootstrap-#{System.unique_integer([:positive])}")

    bootstrap = Path.join(root, "bootstrap")
    config = Path.join(root, "config.json")
    fake = Path.join(root, "fake-rbe")
    File.mkdir_p!(bootstrap)
    File.write!(config, "credential", [:binary])
    File.chmod!(config, 0o600)
    File.write!(Path.join(bootstrap, "configured"), "configured\n", [:binary])
    File.write!(fake, "#!/bin/sh\nexit 78\n", [:binary])
    File.chmod!(fake, 0o700)

    {_output, status} =
      System.cmd("/bin/sh", [@entrypoint],
        stderr_to_stdout: true,
        env: [
          {"ROBINE_BUNDLED_RUNNER_BINARY", fake},
          {"ROBINE_BUNDLED_RUNNER_CONFIG", config},
          {"ROBINE_BUNDLED_RUNNER_BOOTSTRAP_DIRECTORY", bootstrap},
          {"ROBINE_PUBLIC_URL", "https://ci.example.test"}
        ]
      )

    assert status == 78
    refute File.exists?(config)
    refute File.exists?(Path.join(bootstrap, "configured"))

    on_exit(fn -> File.rm_rf(root) end)
  end
end
