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

  test "requires an absolute allowlisted root for deployment runners" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "robine-runner-deployments-#{System.unique_integer([:positive])}"
      )

    path = Path.join(directory, "config.json")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    base = %{
      "server_url" => "https://ci.example.test",
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_" <> String.duplicate("a", 43),
      "deployments" => true
    }

    File.write!(path, Jason.encode!(Map.put(base, "deployment_roots", ["relative/root"])))
    File.chmod!(path, 0o600)

    assert {:exit, 3, "Cannot load runner config: invalid_deployment_roots"} =
             CLI.run(["start", "--config", path])

    File.write!(path, Jason.encode!(Map.put(base, "deployment_roots", ["/srv/robine"])))
    File.chmod!(path, 0o600)

    assert {:start, config} = CLI.run(["start", "--config", path])
    assert config["deployment_roots"] == ["/srv/robine"]
  end

  test "requires deployment root when enrolling a deployment runner" do
    System.put_env("ROBINE_RUNNER_ENROLLMENT_TOKEN", "one-use-token")

    assert {:exit, 64, message} =
             CLI.run([
               "enroll",
               "--server",
               "https://ci.example.test",
               "--name",
               "deployer",
               "--config",
               "/tmp/not-written",
               "--deployments"
             ])

    assert message =~ "--deployment-root is required"
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

  test "the standalone enrollment path starts its HTTP client application" do
    source = File.read!("lib/robine/adapters/runner/cli.ex")

    assert length(Regex.scan(~r/Application\.ensure_all_started\(:req\)/, source)) == 2
    assert source =~ "Application.ensure_all_started(:websockex)"
  end
end
