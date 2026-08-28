defmodule Robine.Adapters.Runner.GoRunnerProtocolSmokeTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.{OutboxDeliveryWorker, RunNextJobWorker}
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Artifact, Attempt}
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

    runner_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, Ecto.UUID.generate())

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(
               %{token: enrollment.token, name: "go-runner-smoke"},
               runner_context
             )

    config_path = Path.join(System.tmp_dir!(), "robine-go-runner-#{Ecto.UUID.generate()}.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        server_url: server_url,
        runner_id: identity.runner_id,
        credential: identity.credential,
        name: "go-runner-smoke"
      })
    )

    File.chmod!(config_path, 0o600)

    port =
      Port.open({:spawn_executable, @runner_binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start", "--config", config_path]
      ])

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      File.rm(config_path)
    end)

    assert_eventually(fn ->
      case Runners.list_fleet(%{}, admin_context) do
        {:ok, [%{connectivity: :online, capabilities: %{"native" => true}}]} -> true
        _other -> false
      end
    end)

    repository_id = Ecto.UUID.generate()

    assert {:ok, _pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "Go macOS runner smoke",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{
                   "build-app" => %{
                     needs: [],
                     image: "native",
                     runs_on: ["linux", "amd64"],
                     steps: [
                       %{
                         name: "Build app-shaped bundle",
                         kind: :run,
                         value:
                           "mkdir -p build/Fixture.app/Contents/MacOS; printf executable > build/Fixture.app/Contents/MacOS/Fixture; chmod +x build/Fixture.app/Contents/MacOS/Fixture"
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
