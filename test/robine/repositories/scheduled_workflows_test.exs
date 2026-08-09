defmodule Robine.Repositories.ScheduledWorkflowsTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  alias Robine.Adapters.Background.OutboxDeliveryWorker

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    Job,
    Pipeline,
    ScheduleReconciliationState
  }

  alias Robine.{Pipelines, Repositories, Runners}
  alias Robine.Repositories.Domain.ScheduleOccurrence
  alias Robine.Runtime.Dependencies

  defmodule FixedClock do
    def now, do: ~U[2026-08-09 08:00:37.123456Z]
  end

  defmodule LaterClock do
    def now, do: ~U[2026-08-09 08:02:42.654321Z]
  end

  defmodule ThreeMinutesLaterClock do
    def now, do: ~U[2026-08-09 08:03:00Z]
  end

  defmodule FakeGitHub do
    @behaviour Robine.Repositories.Ports.GitHub

    @sha String.duplicate("d", 40)

    @impl true
    def default_branch_head(repository) do
      sha =
        case Process.get({__MODULE__, :head}) do
          :new -> String.duplicate("e", 40)
          :invalid -> "MAIN"
          _default -> @sha
        end

      send(self(), {:schedule_head, repository.id, sha})
      {:ok, %{branch: "main", sha: sha}}
    end

    @impl true
    def workflow_files(repository, sha) do
      send(self(), {:schedule_files, repository.id, sha})

      case Process.get({__MODULE__, :mode}, :ok) do
        :api_error ->
          {:error, :github_unavailable}

        :invalid ->
          {:ok, [%{path: ".robine-ci/workflows/nightly.yml", content: "jobs: ["}]}

        mode when mode in [:ok, :no_due] ->
          cron = if mode == :no_due, do: "0 0 31 2 *", else: "* * * * *"

          {:ok,
           [
             %{
               path: ".robine-ci/workflows/nightly.yml",
               content: """
               version: 1
               name: Nightly
               on:
                 schedule:
                   - cron: "#{cron}"
               includes:
                 quality:
                   path: .robine-ci/workflows/nightly-quality.yml
                   inputs:
                     runtime: "3.22"
               jobs: {}
               """
             },
             %{
               path: ".robine-ci/workflows/nightly-quality.yml",
               content: """
               version: 1
               name: Nightly quality
               on:
                 workflow_call:
                   inputs:
                     runtime:
                       type: choice
                       required: true
                       options: ["3.21", "3.22"]
               jobs:
                 test:
                   strategy:
                     matrix:
                       otp: ["28", "29"]
                   image: alpine:3.22
                   steps:
                     - run: echo scheduled
               """
             }
           ]}
      end
    end

    @impl true
    def source_files(_repository, _sha), do: {:ok, []}
    @impl true
    def upsert_check(repository, check) do
      send(self(), {:scheduled_check, repository.id, check})
      {:ok, :erlang.phash2(check.external_id)}
    end

    @impl true
    def installation_permissions(_repository), do: {:ok, %{}}
    @impl true
    def available_repositories, do: {:ok, []}
  end

  test "creates each due exact-SHA occurrence once and catches up bounded missed minutes" do
    previous_adapter = Application.fetch_env!(:robine, :github_adapter)
    Application.put_env(:robine, :github_adapter, FakeGitHub)
    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous_adapter) end)

    context = context(FixedClock)
    repository = register(context, 71_001)
    sha = String.duplicate("d", 40)

    assert {:ok,
            %{
              scanned_minutes: 1,
              due_occurrences: 1,
              pipelines: 1,
              truncated_minutes: 0,
              cursor: ~U[2026-08-09 08:00:00.000000Z]
            }} = Repositories.reconcile_scheduled_workflows(%{}, context)

    assert_receive {:schedule_head, repository_id, ^sha}
    assert repository_id == repository.id
    assert_receive {:schedule_files, ^repository_id, ^sha}

    pipeline = Repo.one!(Pipeline)
    assert pipeline.trigger == "schedule"
    assert pipeline.actor == "system:scheduler"
    assert pipeline.scheduled_for == ~U[2026-08-09 08:00:00.000000Z]
    assert pipeline.commit_sha == sha
    assert Repo.aggregate(Job, :count) == 2
    assert Repo.aggregate(Oban.Job, :count) == 1

    audit = Repo.one!(AuditEvent)
    assert audit.action == "workflow.scheduled_launch"
    assert audit.metadata["scheduled_for"] == "2026-08-09T08:00:00.000000Z"
    assert audit.metadata["cron"] == "* * * * *"

    assert {:ok, 3} = Repositories.sync_github_checks(%{pipeline_id: pipeline.id}, context)

    assert_receive {:scheduled_check, ^repository_id,
                    %{
                      external_id: "pipeline:" <> _,
                      output: %{
                        summary:
                          "Pipeline is created. Trigger: schedule for 2026-08-09T08:00:00.000000Z."
                      }
                    }}

    anonymous_runner =
      Dependencies.context(%{id: "anonymous", role: :runner}, "scheduled-remote")

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, context)

    assert {:ok, identity} =
             Runners.enroll(
               %{token: enrollment.token, name: "scheduled-runner"},
               anonymous_runner
             )

    runner_context =
      Dependencies.context(%{id: identity.runner_id, role: :runner}, "scheduled-remote")

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{"docker" => true, "concurrency" => 1}
               },
               runner_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    assert {:ok, attempt} =
             Pipelines.claim_next_job(%{runner_id: identity.runner_id}, context)

    assert {:ok, remote_execution} =
             Pipelines.remote_job_execution(%{attempt_id: attempt.id}, runner_context)

    assert remote_execution["pipeline_id"] == pipeline.id
    assert remote_execution["commit_sha"] == sha
    assert remote_execution["env"]["ROBINE_MATRIX_OTP"] in ["28", "29"]
    assert remote_execution["env"]["ROBINE_CALL_INPUT_RUNTIME"] == "3.22"

    assert {:ok, revision} = Pipelines.workflow_revision(%{pipeline_id: pipeline.id}, context)

    assert revision.included_sources[".robine-ci/workflows/nightly-quality.yml"]["source"] =~
             "workflow_call"

    assert {:ok, %{scanned_minutes: 0, due_occurrences: 0, pipelines: 0}} =
             Repositories.reconcile_scheduled_workflows(%{}, context)

    refute_received {:schedule_head, _, _}

    later = context(LaterClock)

    assert {:ok, %{scanned_minutes: 2, due_occurrences: 2, pipelines: 2}} =
             Repositories.reconcile_scheduled_workflows(%{}, later)

    assert_receive {:schedule_head, ^repository_id, _sha}
    assert_receive {:schedule_files, ^repository_id, _sha}
    refute_received {:schedule_head, _, _}
    assert Repo.aggregate(Pipeline, :count) == 3
    assert Repo.aggregate(Job, :count) == 6

    assert Repo.get!(ScheduleReconciliationState, "workflows").cursor ==
             ~U[2026-08-09 08:02:00.000000Z]
  end

  test "retains the cursor across GitHub and validation failures, then recovers every minute" do
    context = context(FixedClock)
    _repository = register(context, 71_002)
    assert {:ok, %{pipelines: 1}} = Repositories.reconcile_scheduled_workflows(%{}, context)

    later = context(ThreeMinutesLaterClock)
    Process.put({FakeGitHub, :mode}, :api_error)
    assert {:error, :github_unavailable} = Repositories.reconcile_scheduled_workflows(%{}, later)

    failed_state = Repo.get!(ScheduleReconciliationState, "workflows")
    assert failed_state.cursor == ~U[2026-08-09 08:00:00.000000Z]
    assert failed_state.last_failure == "github_unavailable"

    Process.put({FakeGitHub, :mode}, :invalid)

    assert {:error, {:invalid_workflow, ".robine-ci/workflows/nightly.yml", _diagnostics}} =
             Repositories.reconcile_scheduled_workflows(%{}, later)

    assert Repo.aggregate(Pipeline, :count) == 1

    Process.put({FakeGitHub, :mode}, :ok)

    assert {:ok, %{scanned_minutes: 3, due_occurrences: 3, pipelines: 3}} =
             Repositories.reconcile_scheduled_workflows(%{}, later)

    assert Repo.aggregate(Pipeline, :count) == 4
    assert Repo.get!(ScheduleReconciliationState, "workflows").last_failure == nil
  end

  test "rejects an invalid provider head before fetching and recovers from a first-scan failure" do
    context = context(FixedClock)
    _repository = register(context, 71_006)

    Process.put({FakeGitHub, :head}, :invalid)

    assert {:error, :invalid_default_branch_head} =
             Repositories.reconcile_scheduled_workflows(%{}, context)

    refute_received {:schedule_files, _, _}
    failed = Repo.get!(ScheduleReconciliationState, "workflows")
    assert failed.cursor == nil
    assert failed.last_failure == "invalid_default_branch_head"

    Process.delete({FakeGitHub, :head})

    assert {:ok, %{scanned_minutes: 1, pipelines: 1}} =
             Repositories.reconcile_scheduled_workflows(%{}, context)

    recovered = Repo.get!(ScheduleReconciliationState, "workflows")
    assert recovered.cursor == ~U[2026-08-09 08:00:00.000000Z]
    assert recovered.last_failure == nil
  end

  test "bounds a long outage to the newest 1,440 minutes and reports truncation" do
    context = context(ThreeMinutesLaterClock)
    _repository = register(context, 71_004)
    Process.put({FakeGitHub, :mode}, :no_due)

    old = ~U[2026-08-07 08:00:00.000000Z]

    Repo.insert!(%ScheduleReconciliationState{
      key: "workflows",
      cursor: old,
      last_attempt_at: old,
      last_success_at: old
    })

    assert {:ok,
            %{
              scanned_minutes: 1_440,
              truncated_minutes: 1_443,
              due_occurrences: 0,
              pipelines: 0
            }} = Repositories.reconcile_scheduled_workflows(%{}, context)

    assert Repo.aggregate(Pipeline, :count) == 0
    assert_receive {:schedule_head, _, _}
    assert_receive {:schedule_files, _, _}
    refute_received {:schedule_head, _, _}
  end

  test "concurrent first scans converge on one pipeline and one cursor" do
    context = context(FixedClock)
    _repository = register(context, 71_003)

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Repositories.reconcile_scheduled_workflows(%{}, context) end,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(
             results,
             &match?({:ok, %{cursor: ~U[2026-08-09 08:00:00.000000Z]}}, &1)
           )

    assert Repo.aggregate(Pipeline, :count) == 1
    assert Repo.aggregate(Job, :count) == 2
    assert Repo.aggregate(ScheduleReconciliationState, :count) == 1
  end

  test "an occurrence created before a failed scan wins if the default head moves before retry" do
    context = context(FixedClock)
    repository = register(context, 71_005)
    slot = ~U[2026-08-09 08:00:00.000000Z]
    path = ".robine-ci/workflows/nightly.yml"
    cron = "* * * * *"

    key = ScheduleOccurrence.idempotency_key(repository.id, path, cron, slot)

    assert {:ok, existing} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository.id,
                 workflow_name: "Nightly",
                 commit_sha: String.duplicate("d", 40),
                 trigger: :schedule,
                 scheduled_for: slot,
                 idempotency_key: key,
                 jobs: %{"original" => %{needs: []}},
                 workflow_revision: %{path: path, source: "original exact revision"}
               },
               context
             )

    previous = DateTime.add(slot, -1, :minute)

    Repo.insert!(%ScheduleReconciliationState{
      key: "workflows",
      cursor: previous,
      last_attempt_at: previous,
      last_success_at: previous
    })

    Process.put({FakeGitHub, :head}, :new)

    assert {:ok, %{scanned_minutes: 1, due_occurrences: 1, pipelines: 1}} =
             Repositories.reconcile_scheduled_workflows(%{}, context)

    assert Repo.aggregate(Pipeline, :count) == 1
    assert Repo.get!(Pipeline, existing.id).commit_sha == String.duplicate("d", 40)
    assert Repo.aggregate(Job, :count) == 1
    assert Repo.get!(ScheduleReconciliationState, "workflows").cursor == slot
  end

  defp context(clock) do
    base =
      Dependencies.context(
        %{id: "system:scheduler", role: :administrator},
        "schedule-test"
      )

    repository_dependencies = base.dependencies.repositories
    configured = %{repository_dependencies | source_control: FakeGitHub, clock: clock}
    %{base | dependencies: Map.put(base.dependencies, :repositories, configured)}
  end

  defp register(context, provider_id) do
    assert {:ok, view} =
             Repositories.register_github_repository(
               %{provider_id: provider_id, installation_id: 71, full_name: "acme/scheduled"},
               context
             )

    view
  end
end
