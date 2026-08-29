defmodule Mix.Tasks.Robine.ServerReleaseSmoke do
  use Mix.Task

  @shortdoc "Builds and verifies the real server release archive"

  @impl true
  def run([]) do
    root = Path.join(System.tmp_dir!(), "robine-server-release-smoke-#{unique_id()}")
    output = Path.join(root, "bundle")
    extracted = Path.join(root, "extracted")

    try do
      build_bundle!(output)
      artifact = artifact!(output)
      verify_checksum!(output)
      verify_archive!(artifact, extracted)
      verify_release_script!(extracted)
      Mix.shell().info("Server release smoke passed")
    after
      File.rm_rf!(root)
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix robine.server_release_smoke")

  defp build_bundle!(output) do
    {log, status} =
      System.cmd("mix", ["robine.server_release", "--output", output],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    require_status!(status, 0, "server release build", log)
  end

  defp artifact!(output) do
    artifacts = Path.wildcard(Path.join(output, "robine-server-*.tar.gz"))

    case artifacts do
      [artifact] -> artifact
      _invalid -> Mix.raise("server release produced #{length(artifacts)} archives, expected one")
    end
  end

  defp verify_checksum!(output) do
    manifest = Path.join(output, "SHA256SUMS")

    case Robine.Release.Checksums.verify(manifest, output) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("server release checksum failed: #{inspect(reason)}")
    end
  end

  defp verify_archive!(artifact, extracted) do
    File.mkdir_p!(extracted)

    {log, status} =
      System.cmd("tar", ["-xzf", artifact, "-C", extracted], stderr_to_stdout: true)

    require_status!(status, 0, "server release extraction", log)

    release_root = Path.join(extracted, "robine")

    required = [
      "bin/robine",
      "bin/rbe",
      "bin/start-bundled-runner",
      "compose.yaml",
      "Caddyfile",
      ".env.example",
      "install.sh",
      "RELEASE_PLATFORM",
      "LICENSE",
      "THIRD_PARTY_NOTICES.md",
      "releases/#{version()}/env.sh"
    ]

    missing = Enum.reject(required, &File.regular?(Path.join(release_root, &1)))

    if missing != [] do
      Mix.raise("server release is missing required files: #{Enum.join(missing, ", ")}")
    end

    verify_bundled_runner!(release_root)

    assert_exact_file!(Path.join(release_root, "LICENSE"), "LICENSE")

    assert_exact_file!(
      Path.join(release_root, "THIRD_PARTY_NOTICES.md"),
      "THIRD_PARTY_NOTICES.md"
    )

    environment = File.read!(Path.join(release_root, "releases/#{version()}/env.sh"))

    unless environment =~ "export RELEASE_DISTRIBUTION=none" and
             environment =~ "unset RELEASE_NODE" do
      Mix.raise("server release does not disable Erlang Distribution")
    end

    verify_installation_bundle!(release_root)
  end

  defp verify_installation_bundle!(release_root) do
    installer = Path.join(release_root, "install.sh")
    {syntax_log, syntax_status} = System.cmd("sh", ["-n", installer], stderr_to_stdout: true)
    require_status!(syntax_status, 0, "server installer syntax", syntax_log)

    {prepare_log, prepare_status} =
      System.cmd(installer, ["--prepare-only", "ci.example.test"],
        cd: release_root,
        stderr_to_stdout: true
      )

    require_status!(prepare_status, 0, "server installer preparation", prepare_log)

    environment_path = Path.join(release_root, ".env")
    environment = File.read!(environment_path)
    permissions = File.stat!(environment_path).mode |> Bitwise.band(0o777)

    unless permissions == 0o600 do
      Mix.raise("server installer wrote .env with mode #{Integer.to_string(permissions, 8)}")
    end

    required_variables = ~w(
      ROBINE_HOST ROBINE_PUBLIC_URL PHX_HOST PHX_SERVER PORT DATABASE_URL
      POSTGRES_PASSWORD SECRET_KEY_BASE ROBINE_CI_SECRET_KEY ROBINE_BOOTSTRAP_TOKEN
      ROBINE_STORAGE_ROOT
      ROBINE_BUNDLED_RUNNER_ENABLED ROBINE_LOCAL_RUNNER_ENABLED
      ROBINE_BUNDLED_RUNNER_BOOTSTRAP_DIRECTORY ROBINE_BUNDLED_RUNNER_NAME
      ROBINE_RUNTIME_IMAGE
    )

    unless Enum.all?(required_variables, &String.contains?(environment, "#{&1}=")) and
             not String.contains?(environment, "replace-with") do
      Mix.raise("server installer did not generate every required environment value")
    end

    if Regex.match?(~r/[A-Fa-f0-9]{48}/, prepare_log) do
      Mix.raise("server installer leaked generated secrets during prepare-only verification")
    end

    {compose_log, compose_status} =
      System.cmd("docker", ["compose", "--env-file", ".env", "config", "--quiet"],
        cd: release_root,
        stderr_to_stdout: true
      )

    require_status!(compose_status, 0, "server Compose validation", compose_log)
    verify_caddy_configuration!(release_root)
    verify_compose_runtime!(release_root)
  end

  defp verify_bundled_runner!(release_root) do
    executable = Path.join(release_root, "bin/rbe")
    entrypoint = Path.join(release_root, "bin/start-bundled-runner")

    unless executable?(executable) and executable?(entrypoint) do
      Mix.raise("bundled runner binary and entrypoint must be executable")
    end

    {log, status} = System.cmd(executable, ["version"], stderr_to_stdout: true)
    require_status!(status, 0, "bundled runner version", log)

    unless String.trim(log) == "robine-runner #{version()}" do
      Mix.raise("bundled runner returned unexpected version output: #{inspect(log)}")
    end
  end

  defp executable?(path), do: File.stat!(path).mode |> Bitwise.band(0o111) != 0

  defp verify_caddy_configuration!(release_root) do
    project = "robine-caddy-smoke-#{System.unique_integer([:positive])}"
    compose = ["compose", "--project-name", project, "--env-file", ".env"]

    try do
      {log, status} =
        System.cmd(
          "docker",
          compose ++
            [
              "run",
              "--rm",
              "--no-deps",
              "proxy",
              "caddy",
              "validate",
              "--config",
              "/etc/caddy/Caddyfile"
            ],
          cd: release_root,
          stderr_to_stdout: true
        )

      require_status!(status, 0, "Caddy release configuration", log)
    after
      _ =
        System.cmd(
          "docker",
          compose ++ ["down", "--volumes", "--remove-orphans", "--timeout", "1"],
          cd: release_root,
          stderr_to_stdout: true
        )
    end
  end

  defp verify_compose_runtime!(release_root) do
    project = "robine-release-smoke-#{System.unique_integer([:positive])}"
    compose = ["compose", "--project-name", project, "--env-file", ".env"]

    try do
      {start_log, start_status} =
        System.cmd(
          "docker",
          compose ++ ["up", "--detach", "--wait", "postgres", "server"],
          cd: release_root,
          stderr_to_stdout: true
        )

      if start_status != 0 do
        {runtime_logs, _logs_status} =
          System.cmd("docker", compose ++ ["logs", "--no-color", "--tail", "120", "server"],
            cd: release_root,
            stderr_to_stdout: true
          )

        Mix.raise(
          "server Compose runtime exited with #{start_status}:\n" <>
            String.slice(start_log <> "\n" <> runtime_logs, 0, 20_000)
        )
      end

      {services, ps_status} =
        System.cmd("docker", compose ++ ["ps", "--status", "running", "--services"],
          cd: release_root,
          stderr_to_stdout: true
        )

      require_status!(ps_status, 0, "server Compose runtime status", services)

      unless services |> String.split() |> Enum.sort() == ["postgres", "server"] do
        Mix.raise(
          "server Compose runtime did not leave PostgreSQL and Robine healthy: #{services}"
        )
      end
    after
      _ =
        System.cmd(
          "docker",
          compose ++ ["down", "--volumes", "--remove-orphans", "--timeout", "1"],
          cd: release_root,
          stderr_to_stdout: true
        )
    end
  end

  defp verify_release_script!(extracted) do
    executable = Path.join([extracted, "robine", "bin", "robine"])
    {log, status} = System.cmd(executable, ["version"], stderr_to_stdout: true)
    require_status!(status, 0, "server release version", log)

    unless String.trim(log) == "robine #{version()}" do
      Mix.raise("server release returned unexpected version output: #{inspect(log)}")
    end
  end

  defp assert_exact_file!(packaged, source) do
    unless File.read!(packaged) == File.read!(source) do
      Mix.raise("server release contains an unexpected #{Path.basename(source)} payload")
    end
  end

  defp version, do: Mix.Project.config() |> Keyword.fetch!(:version)

  defp require_status!(actual, expected, label, log) do
    if actual != expected do
      Mix.raise("#{label} exited with #{actual}, expected #{expected}:\n#{log}")
    end
  end

  defp unique_id do
    "#{System.pid()}-#{System.unique_integer([:positive])}"
  end
end
