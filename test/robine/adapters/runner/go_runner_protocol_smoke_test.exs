defmodule Robine.Adapters.Runner.GoRunnerProtocolSmokeTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.{OutboxDeliveryWorker, RunNextJobWorker}
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, Attempt}
  alias Robine.Adapters.Runner.BundledBootstrap
  alias Robine.Runtime.Dependencies
  alias Robine.TestSupport.RestartableEndpoint
  alias Robine.{Pipelines, Repo, Runners, Storage}

  @runner_binary System.get_env("ROBINE_GO_RUNNER_TEST_BINARY")

  if is_nil(@runner_binary) do
    @moduletag skip: "set ROBINE_GO_RUNNER_TEST_BINARY to a Linux test build of the Go runner"
  end

  test "the Go runner builds an app-shaped bundle and retains it through the real protocol" do
    endpoint = start_supervised!(RestartableEndpoint)
    server_url = "http://127.0.0.1:#{RestartableEndpoint.port(endpoint)}"
    previous_public_url = Application.fetch_env!(:robine, :public_url)
    Application.put_env(:robine, :public_url, server_url)
    on_exit(fn -> Application.put_env(:robine, :public_url, previous_public_url) end)

    admin_context =
      Dependencies.context(%{id: "go-runner-smoke", role: :administrator}, Ecto.UUID.generate())

    root = Path.join(System.tmp_dir!(), "robine-go-runner-#{Ecto.UUID.generate()}")
    config_path = Path.join(root, "state/config.json")
    bootstrap_directory = Path.join(root, "bootstrap")

    bootstrap =
      start_supervised!(
        {BundledBootstrap,
         name: nil, config: [bootstrap_directory: bootstrap_directory], context: admin_context}
      )

    _ = :sys.get_state(bootstrap)

    entrypoint = Path.expand("../../../../rel/overlays/bin/start-bundled-runner", __DIR__)

    {port, os_pid} =
      start_bundled_runner(entrypoint, config_path, bootstrap_directory, server_url)

    on_exit(fn ->
      if Port.info(port) do
        _ = System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
        Port.close(port)
      end

      File.rm_rf(root)
    end)

    original_runner =
      assert_eventually(fn ->
        case Runners.list_fleet(%{}, admin_context) do
          {:ok, [%{connectivity: :online, capabilities: %{"docker" => true}} = runner]} ->
            {:ok, runner}

          _other ->
            false
        end
      end)

    assert File.stat!(config_path).mode |> Bitwise.band(0o777) == 0o600
    assert File.regular?(Path.join(bootstrap_directory, "configured"))
    refute File.exists?(Path.join(bootstrap_directory, "enrollment-token"))

    repository_id = Ecto.UUID.generate()

    assert {:ok, _pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "Go Docker runner smoke",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{
                   "build-app" => %{
                     needs: [],
                     image:
                       "redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241",
                     runs_on: ["linux", "amd64", "docker"],
                     services: %{
                       "redis" => %{
                         id: "redis",
                         image:
                           "redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241",
                         user: "redis",
                         readiness: %{tcp: 6379, timeout_ms: 30_000}
                       }
                     },
                     steps: [
                       %{
                         name: "Build app-shaped bundle",
                         kind: :run,
                         value:
                           "test \"$(redis-cli -h redis ping)\" = PONG; printf runner-started; sleep 3; mkdir -p build/Fixture.app/Contents/MacOS; printf executable > build/Fixture.app/Contents/MacOS/Fixture; chmod +x build/Fixture.app/Contents/MacOS/Fixture"
                       },
                       %{
                         name: "Upload app",
                         kind: :builtin,
                         value: "artifacts/upload",
                         with: %{
                           "name" => "go-macos-app",
                           "paths" => ["build/Fixture.app"],
                           "retention-days" => 7
                         }
                       }
                     ]
                   }
                 }
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)
    assert :ok = perform_job(RunNextJobWorker, %{})

    assert_eventually(fn ->
      case Repo.one(from attempt in Attempt, order_by: [desc: attempt.inserted_at], limit: 1) do
        %Attempt{status: :running} -> true
        _pending -> false
      end
    end)

    assert :ok = RestartableEndpoint.restart(endpoint)

    attempt =
      assert_eventually(fn ->
        case Repo.one(from attempt in Attempt, order_by: [desc: attempt.inserted_at], limit: 1) do
          %Attempt{status: :succeeded} = attempt ->
            {:ok, attempt}

          %Attempt{status: status, result_reason: reason} when status in [:failed, :cancelled] ->
            flunk(
              "Go runner attempt ended as #{status}: #{inspect(reason)}\n#{port_output(port)}"
            )

          _pending ->
            false
        end
      end)

    artifact = Repo.one!(from artifact in Artifact, where: artifact.attempt_id == ^attempt.id)
    assert artifact.name == "go-macos-app"
    assert artifact.source == :ci

    assert {:ok, download} =
             Storage.download_job_artifact(
               %{job_id: attempt.job_id, name: artifact.name},
               admin_context
             )

    assert {:ok, entries} = :erl_tar.table({:binary, download.content}, [:compressed])
    assert ~c"build/Fixture.app/Contents/MacOS/Fixture" in entries

    assert :ok = Runners.revoke(%{runner_id: original_runner.id}, admin_context)
    assert_receive {^port, {:exit_status, 78}}, 5_000

    assert_eventually(fn ->
      !File.exists?(config_path) &&
        !File.exists?(Path.join(bootstrap_directory, "configured")) &&
        File.regular?(Path.join(bootstrap_directory, "enrollment-token"))
    end)

    {replacement_port, replacement_os_pid} =
      start_bundled_runner(entrypoint, config_path, bootstrap_directory, server_url)

    on_exit(fn -> stop_port(replacement_port, replacement_os_pid) end)

    assert_eventually(fn ->
      with {:ok, runners} <- Runners.list_fleet(%{}, admin_context),
           %{id: replacement_id} <-
             Enum.find(runners, &(&1.connectivity == :online && &1.id != original_runner.id)) do
        replacement_id != original_runner.id
      else
        _other -> false
      end
    end)

    assert File.stat!(config_path).mode |> Bitwise.band(0o777) == 0o600
    refute File.exists?(Path.join(bootstrap_directory, "enrollment-token"))
  end

  defp start_bundled_runner(entrypoint, config_path, bootstrap_directory, server_url) do
    port =
      Port.open({:spawn_executable, System.find_executable("setsid")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--wait", "/bin/sh", entrypoint],
        env: [
          {~c"ROBINE_BUNDLED_RUNNER_BINARY", String.to_charlist(@runner_binary || "")},
          {~c"ROBINE_BUNDLED_RUNNER_CONFIG", String.to_charlist(config_path)},
          {~c"ROBINE_BUNDLED_RUNNER_BOOTSTRAP_DIRECTORY",
           String.to_charlist(bootstrap_directory)},
          {~c"ROBINE_BUNDLED_RUNNER_NAME", ~c"go-runner-smoke"},
          {~c"ROBINE_RUNNER_RESOURCE_NAMESPACE", ~c"go-runner-smoke"},
          {~c"ROBINE_RUNNER_CPU_MILLIS", ~c"2000"},
          {~c"ROBINE_RUNNER_MEMORY_BYTES", ~c"1073741824"},
          {~c"ROBINE_RUNNER_PIDS_LIMIT", ~c"256"},
          {~c"ROBINE_PUBLIC_URL", String.to_charlist(server_url)}
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp stop_port(port, os_pid) do
    if Port.info(port) do
      _ = System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
      Port.close(port)
    end
  end

  defp assert_eventually(probe, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(probe, deadline)
  end

  defp do_assert_eventually(probe, deadline) do
    case probe.() do
      true ->
        true

      {:ok, value} ->
        value

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition was not satisfied before timeout")
        else
          receive do
          after
            25 -> do_assert_eventually(probe, deadline)
          end
        end
    end
  end

  defp port_output(port), do: port_output(port, [])

  defp port_output(port, chunks) do
    receive do
      {^port, {:data, content}} ->
        port_output(port, [content | chunks])

      {^port, {:exit_status, status}} ->
        IO.iodata_to_binary(Enum.reverse(["\nexit status: #{status}" | chunks]))
    after
      0 -> IO.iodata_to_binary(Enum.reverse(chunks))
    end
  end
end
