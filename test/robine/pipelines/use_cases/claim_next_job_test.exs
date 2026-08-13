defmodule Robine.Pipelines.UseCases.ClaimNextJobTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    GitHubRepository,
    Job,
    Pipeline,
    RemoteRunner
  }

  alias Robine.{Pipelines, Runners}
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  test "persists a graph and claims only a ready job within capacity" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "graph")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("d", 40),
                 jobs: %{
                   "build" => %{needs: []},
                   "test" => %{needs: ["build"]}
                 }
               },
               context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    assert {:ok, attempt} =
             Pipelines.claim_next_job(
               %{global_limit: 1, repository_limit: 1, lease_seconds: 30},
               context
             )

    build =
      Repo.one!(
        from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "build"
      )

    test_job =
      Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "test")

    assert attempt.job_id == build.id
    assert build.status == :running
    assert test_job.status == :blocked
    assert Repo.get!(Pipeline, pipeline.id).status == :running

    assert {:error, :capacity} =
             Pipelines.claim_next_job(%{global_limit: 1, repository_limit: 1}, context)
  end

  test "disk pressure refuses admission before creating an attempt or changing job state" do
    previous = Application.fetch_env!(:robine, :runner_admission)

    Application.put_env(:robine, :runner_admission,
      min_free_bytes: 9_223_372_036_854_775_807,
      max_used_percent: 95
    )

    on_exit(fn -> Application.put_env(:robine, :runner_admission, previous) end)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "disk-pressure")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("e", 40),
                 jobs: %{"build" => %{needs: []}}
               },
               context
             )

    assert {:ok, _} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:error, :disk_pressure} = Pipelines.claim_next_job(%{}, context)

    assert %Job{status: :queued} =
             Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline.id)

    assert Repo.aggregate(Robine.Adapters.Persistence.Postgres.Schemas.Attempt, :count) == 0
  end

  test "simultaneous claims run independent jobs without exceeding global capacity" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "concurrency")
    repository_id = Ecto.UUID.generate()

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "Parallel",
                 commit_sha: String.duplicate("f", 40),
                 jobs: %{
                   "alpha" => %{needs: []},
                   "bravo" => %{needs: []},
                   "charlie" => %{needs: []},
                   "delta" => %{needs: []}
                 }
               },
               context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    results =
      1..4
      |> Task.async_stream(
        fn _index ->
          Pipelines.claim_next_job(
            %{global_limit: 2, repository_limit: 2, lease_seconds: 30},
            context
          )
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _attempt}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :capacity})) == 2

    assert Repo.aggregate(Robine.Adapters.Persistence.Postgres.Schemas.Attempt, :count) == 2

    assert Repo.aggregate(
             from(job in Job,
               where: job.pipeline_id == ^pipeline.id and job.status == :running
             ),
             :count
           ) == 2
  end

  test "selects an online remote runner and reserves its declared capacity atomically" do
    admin_context = Dependencies.context(%{id: "admin", role: :administrator}, "remote-capacity")

    runner_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, "remote-capacity")

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "capacity-one"}, runner_context)

    authenticated_runner_context =
      Dependencies.context(%{id: identity.runner_id, role: :runner}, "remote-capacity")

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{"docker" => true, "concurrency" => 1}
               },
               authenticated_runner_context
             )

    runner = Repo.get!(RemoteRunner, identity.runner_id)
    runner |> Ecto.Changeset.change(labels: ["gpu"]) |> Repo.update!()

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Remote capacity",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{
                   "first" => %{needs: [], runs_on: ["docker", "gpu"]},
                   "second" => %{needs: [], runs_on: ["docker", "arm64"]}
                 }
               },
               admin_context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)

    assert {:ok, selected} = Runners.select_available(%{}, admin_context)
    assert selected.id == identity.runner_id
    assert selected.active_attempts == 0

    assert {:ok, attempt} =
             Pipelines.claim_next_job(
               %{runner_id: selected.id, global_limit: 4, repository_limit: 4},
               admin_context
             )

    claimed_job = Repo.get!(Job, attempt.job_id)
    assert claimed_job.job_key == "first"
    assert claimed_job.execution_spec["runs_on"] == ["docker", "gpu"]

    assert attempt.runner_id == identity.runner_id

    assert {:error, :runner_unavailable} =
             Pipelines.claim_next_job(
               %{runner_id: selected.id, global_limit: 4, repository_limit: 4},
               admin_context
             )

    assert {:error, :none} = Runners.select_available(%{}, admin_context)
    assert Repo.get!(Pipeline, pipeline.id).status == :running

    runner = Repo.get!(RemoteRunner, identity.runner_id)
    assert runner.last_seen_at
  end

  test "native macOS capacity claims macOS work but not default Docker work" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "macos-capacity")
    runner_context = Dependencies.context(%{id: "anonymous", role: :runner}, "macos-capacity")

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "mac-mini"}, runner_context)

    authenticated =
      Dependencies.context(%{id: identity.runner_id, role: :runner}, "macos-capacity")

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{
                   "os" => "macos",
                   "architecture" => "arm64",
                   "native" => true,
                   "docker" => false,
                   "executor" => "native",
                   "concurrency" => 1
                 }
               },
               authenticated
             )

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Apple platforms",
                 commit_sha: String.duplicate("b", 40),
                 jobs: %{
                   "linux-default" => %{needs: []},
                   "macos" => %{needs: [], runs_on: ["macos", "arm64"]}
                 }
               },
               context
             )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)
    assert {:ok, selected} = Runners.select_available(%{}, context)

    assert {:ok, attempt} =
             Pipelines.claim_next_job(%{runner_id: selected.id}, context)

    claimed = Repo.get!(Job, attempt.job_id)
    assert claimed.job_key == "macos"
    assert claimed.execution_spec["runs_on"] == ["macos", "arm64"]

    default =
      Repo.one!(
        from job in Job, where: job.pipeline_id == ^pipeline.id and job.job_key == "linux-default"
      )

    assert default.status == :queued
  end

  test "a saturated repository cannot hide another repository behind a deep queue" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "fairness")
    first_repository = Ecto.UUID.generate()
    second_repository = Ecto.UUID.generate()

    many_jobs = Map.new(1..25, &{"job-#{&1}", %{needs: []}})

    assert {:ok, first} =
             Pipelines.create_pipeline(
               %{
                 repository_id: first_repository,
                 workflow_name: "Deep queue",
                 commit_sha: String.duplicate("1", 40),
                 jobs: many_jobs
               },
               context
             )

    assert {:ok, second} =
             Pipelines.create_pipeline(
               %{
                 repository_id: second_repository,
                 workflow_name: "Fair queue",
                 commit_sha: String.duplicate("2", 40),
                 jobs: %{"only" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} =
             Pipelines.queue_pipeline(%{pipeline_id: first.id}, context)

    assert {:ok, _queued} =
             Pipelines.queue_pipeline(%{pipeline_id: second.id}, context)

    assert {:ok, first_attempt} =
             Pipelines.claim_next_job(
               %{global_limit: 4, repository_limit: 1},
               context
             )

    assert {:ok, second_attempt} =
             Pipelines.claim_next_job(
               %{global_limit: 4, repository_limit: 1},
               context
             )

    first_job = Repo.get!(Job, first_attempt.job_id)
    second_job = Repo.get!(Job, second_attempt.job_id)
    first_pipeline = Repo.get!(Pipeline, first_job.pipeline_id)
    second_pipeline = Repo.get!(Pipeline, second_job.pipeline_id)

    assert first_pipeline.repository_id == first_repository
    assert second_pipeline.repository_id == second_repository
  end

  test "selecting capacity stays below 100ms at p95 with 1,000 registered runners" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "fleet-performance")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..1_000, fn index ->
        %{
          id: Ecto.UUID.generate(),
          name: "perf-#{index}",
          admin_state: :enabled,
          protocol_version: 1,
          software_version: "0.2.0-dev",
          capabilities: %{"docker" => true, "concurrency" => 1},
          labels: [],
          last_seen_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    {1_000, _rows} = Repo.insert_all(RemoteRunner, rows)
    assert {:ok, _runner} = Runners.select_available(%{}, context)

    durations =
      Enum.map(1..20, fn _iteration ->
        started = System.monotonic_time()
        assert {:ok, _runner} = Runners.select_available(%{}, context)
        System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
      end)

    p95 = durations |> Enum.sort() |> Enum.at(18)
    assert p95 < 100, "expected p95 < 100ms, measured #{p95}ms from #{inspect(durations)}"
  end

  test "never claims work from a repository explicitly marked untrusted" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "trust-placement")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    untrusted_id = Ecto.UUID.generate()

    Repo.insert!(%GitHubRepository{
      id: untrusted_id,
      provider_id: 999_001,
      installation_id: 999_002,
      owner: "unsafe",
      name: "repository",
      full_name: "unsafe/repository",
      trusted: false,
      inserted_at: now
    })

    assert {:ok, untrusted_pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: untrusted_id,
                 workflow_name: "Untrusted",
                 commit_sha: String.duplicate("3", 40),
                 jobs: %{"unsafe" => %{needs: []}}
               },
               context
             )

    assert {:ok, trusted_pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Trusted internal",
                 commit_sha: String.duplicate("4", 40),
                 jobs: %{"safe" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} =
             Pipelines.queue_pipeline(%{pipeline_id: untrusted_pipeline.id}, context)

    assert {:ok, _queued} =
             Pipelines.queue_pipeline(%{pipeline_id: trusted_pipeline.id}, context)

    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)
    claimed = Repo.get!(Job, attempt.job_id)
    assert claimed.pipeline_id == trusted_pipeline.id

    assert Repo.one!(
             from job in Job,
               where: job.pipeline_id == ^untrusted_pipeline.id
           ).status == :queued
  end
end
