defmodule Robine.Adapters.Runner.CLITest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Runner.CLI

  test "loads only a private, structurally valid runner config" do
    directory =
      Path.join(System.tmp_dir!(), "robine-runner-cli-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "config.json")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    credential = "rrc_" <> String.duplicate("a", 43)

    File.write!(
      path,
      Jason.encode!(%{
        "server_url" => "https://ci.example.test",
        "runner_id" => Ecto.UUID.generate(),
        "credential" => credential
      })
    )

    File.chmod!(path, 0o644)

    assert {:exit, 4, message} = CLI.run(["start", "--config", path])
    assert message =~ "must not be readable"
    refute message =~ credential

    File.chmod!(path, 0o600)
    assert {:start, config} = CLI.run(["start", "--config", path])
    assert config["credential"] == credential
  end

  test "rejects insecure non-loopback server URLs in config" do
    directory =
      Path.join(System.tmp_dir!(), "robine-runner-cli-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "config.json")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    File.write!(
      path,
      Jason.encode!(%{
        "server_url" => "http://ci.example.test",
        "runner_id" => Ecto.UUID.generate(),
        "credential" => "rrc_secret"
      })
    )

    File.chmod!(path, 0o600)

    assert {:exit, 3, "Cannot load runner config: tls_required"} =
             CLI.run(["start", "--config", path])
  end

  test "requires enrollment secrets through the environment, not argv" do
    System.delete_env("ROBINE_RUNNER_ENROLLMENT_TOKEN")

    assert {:exit, 64, message} =
             CLI.run([
               "enroll",
               "--server",
               "https://ci.example.test",
               "--name",
               "builder",
               "--config",
               "/tmp/not-written"
             ])

    assert message =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN is required"
    refute message =~ "--token"
  end
end
