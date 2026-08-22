defmodule RobineWeb.PipelineLiveTest do
  use RobineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Robine.Pipelines
  alias Robine.Adapters.Persistence.Postgres.Schemas.User
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  test "redirects anonymous users to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/pipelines")
  end

  test "renders pipeline history, dependency state, and stable job deep links", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "live-test")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("e", 40),
                 source_ref: "main",
                 jobs: %{"build" => %{needs: []}, "test" => %{needs: ["build"]}},
                 workflow_revision: %{
                   path: ".robine-ci/workflows/ci.yml",
                   source: "version: 1\nname: CI\n",
                   sources: %{
                     ".robine-ci/workflows/quality.yml" =>
                       "version: 1\nname: Quality\non: {workflow_call: {}}\n"
                   }
                 }
               },
               context
             )

    assert {:ok, index, html} = live(conn, ~p"/pipelines")
    assert html =~ "Pipelines"
    assert has_element?(index, ".app-shell.h-dvh.overflow-hidden")
    assert has_element?(index, ".sidebar-brand", "Your code stays yours.")
    assert has_element?(index, ".app-nav-link-active", "Runs, failures & history")
    assert has_element?(index, ".sidebar-account", "admin@example.com")
    assert has_element?(index, ".app-content.h-dvh.overflow-y-auto.overscroll-y-none")
    assert has_element?(index, "img[src='/images/brand/robine-mark.png']")
    assert has_element?(index, "img[src='/images/brand/robine-mark-dark.png']")
    assert has_element?(index, "#pipeline-#{pipeline.id}", "CI")
    assert has_element?(index, "#pipeline-watchlist #pipeline-#{pipeline.id}", "main")
    assert has_element?(index, "#pipeline-filters")
    assert has_element?(index, "#pipeline-search")
    assert has_element?(index, "#pipeline-status-filter")
    assert has_element?(index, "#pipeline-repository-filter")
    assert has_element?(index, "#pipeline-refresh-status", "Up to date")
    assert has_element?(index, "#application-build-footer a[href='/build-information']")
    assert has_element?(index, "a[aria-label='About this Robine build']")
    assert has_element?(index, "a[href='/pipelines'][aria-current='page']")

    assert has_element?(
             index,
             "#pipeline-#{pipeline.id} a[aria-label='Open CI in Unknown repository']"
           )

    assert has_element?(
             index,
             "#pipeline-#{pipeline.id} time[datetime='#{DateTime.to_iso8601(pipeline.inserted_at)}']"
           )

    index
    |> form("#pipeline-filters", filters: %{query: "no-such-workflow"})
    |> render_change()

    assert assert_patch(index) == "/pipelines?filters[query]=no-such-workflow"
    assert has_element?(index, "#pipeline-result-count", "0 pipelines")
    assert has_element?(index, "#clear-pipeline-filters")

    index |> element("#clear-pipeline-filters") |> render_click()
    assert_patch(index, "/pipelines")
    assert has_element?(index, "#pipeline-#{pipeline.id}", "CI")

    assert {:ok, build_info, _html} = live(conn, ~p"/build-information")
    assert has_element?(build_info, "#build-provenance", "Commit SHA")
    assert has_element?(build_info, "#build-provenance", "Source reference")
    assert has_element?(build_info, "#build-provenance", "Built at")

    assert {:ok, show, html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    assert html =~ "Dependency order"
    assert html =~ "Needs: build"
    assert show |> element("button", "Cancel pipeline") |> render_click() =~ "cancelled"

    snapshot = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context) |> elem(1)
    job = Enum.find(snapshot.jobs, &(&1.job_key == "test"))
    assert has_element?(show, "a[href='/pipelines/#{pipeline.id}/jobs/#{job.id}']", "test")
    assert has_element?(show, "#workflow-revision-link")

    assert {:ok, revision_view, _html} = live(conn, ~p"/pipelines/#{pipeline.id}/workflow")
    assert has_element?(revision_view, "#workflow-revision-title", ".robine-ci/workflows/ci.yml")
    assert has_element?(revision_view, "#workflow-revision-source", "version: 1")
    assert has_element?(revision_view, "#workflow-revision-digest")
    assert has_element?(revision_view, "#workflow-revision-graph", "build")

    assert has_element?(
             revision_view,
             "#included-workflow-revisions",
             ".robine-ci/workflows/quality.yml"
           )

    assert render(revision_view) =~ "workflow_call"

    assert {:ok, _job_view, job_html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")
    assert job_html =~ "robine run test"
    assert job_html =~ "CI-only inputs"
  end

  test "a viewer cannot forge the hidden pipeline cancellation event", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "forged-live-event")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Protected CI",
                 commit_sha: String.duplicate("f", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    assert {:ok, view, html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    refute html =~ "Cancel pipeline"

    assert render_hook(view, "cancel", %{}) =~
             "You do not have permission to cancel pipelines."

    assert {:ok, snapshot} = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context)
    assert snapshot.status == :created
  end

  test "shows the intended UTC occurrence for a scheduled pipeline", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "system:scheduler", role: :administrator}, "schedule-ui")
    scheduled_for = ~U[2026-08-09 02:00:00Z]

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Nightly",
                 commit_sha: String.duplicate("8", 40),
                 trigger: :schedule,
                 scheduled_for: scheduled_for,
                 jobs: %{"nightly" => %{needs: []}}
               },
               context
             )

    assert {:ok, view, html} = live(conn, ~p"/pipelines/#{pipeline.id}")

    assert has_element?(
             view,
             "#scheduled-for time[datetime='2026-08-09T02:00:00.000000Z']"
           )

    assert html =~ "Intended schedule"
    assert html =~ "schedule"
  end

  test "shows trigger, actor, duration, complete logs, and infrastructure failure", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "pipeline-metadata")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Infrastructure CI",
                 commit_sha: String.duplicate("d", 40),
                 trigger: :manual,
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 1, status: :preparing},
               context
             )

    assert :ok =
             Pipelines.append_log_event(
               %{
                 attempt_id: attempt.id,
                 sequence: 1,
                 phase: :image_acquisition,
                 step_position: 0,
                 step_name: "Image acquisition",
                 status: :succeeded,
                 duration_ms: 10,
                 content: "Image available locally"
               },
               context
             )

    assert :ok =
             Pipelines.append_log_event(
               %{
                 attempt_id: attempt.id,
                 sequence: 1_000_001,
                 phase: :execution,
                 stream: :system,
                 step_position: 0,
                 step_name: "Runner preparation",
                 status: :failed,
                 duration_ms: 12,
                 content: "runner unavailable"
               },
               context
             )

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 2, status: :running},
               context
             )

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{
                 idempotency_token: attempt.idempotency_token,
                 sequence: 3,
                 status: :failed,
                 reason: :system_failure
               },
               context
             )

    assert {:ok, index_view, _index_html} = live(conn, ~p"/pipelines")
    assert has_element?(index_view, "#pipeline-#{pipeline.id}", "Failed in test")

    assert {:ok, view, html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    assert html =~ "Infrastructure failure"
    assert html =~ "runner unavailable"

    assert has_element?(
             view,
             "#pipeline-failure-detail-#{attempt.job_id}",
             "runner unavailable"
           )

    assert html =~ "Trigger"
    assert html =~ "manual"
    assert html =~ "Actor"
    assert html =~ "admin"
    assert html =~ String.duplicate("d", 40)
    assert html =~ "Phase: failed"
    assert html =~ "Reason: system failure"
    assert html =~ "Duration"

    snapshot = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context) |> elem(1)
    job = hd(snapshot.jobs)

    assert has_element?(
             index_view,
             "#pipeline-#{pipeline.id} a[href='/pipelines/#{pipeline.id}/jobs/#{job.id}']",
             "Failed in test"
           )

    assert {:ok, job_view, _job_html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")

    assert has_element?(
             job_view,
             "#complete-log-viewer[phx-hook='RetainedLogViewer'][phx-update='ignore'][data-url*='view=inline']"
           )

    assert has_element?(job_view, "#complete-log-viewer [data-log-viewport][tabindex='0']")

    inline_conn =
      get(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}/logs?view=inline")

    inline_log = response(inline_conn, 200)
    assert inline_log =~ "Image available locally"
    assert inline_log =~ "runner unavailable"
  end

  test "explains a skipped job's fixed condition", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "skipped-job-live")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Conditional CI",
                 commit_sha: String.duplicate("c", 40),
                 jobs: %{
                   "build" => %{needs: []},
                   "publish" => %{needs: ["build"], condition: :success}
                 }
               },
               context
             )

    assert {:ok, _} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    for {sequence, status, reason} <- [
          {1, :preparing, nil},
          {2, :running, nil},
          {3, :failed, :command_failed}
        ] do
      assert {:ok, _} =
               Pipelines.record_runner_event(
                 %{
                   idempotency_token: attempt.idempotency_token,
                   sequence: sequence,
                   status: status,
                   reason: reason
                 },
                 context
               )
    end

    snapshot = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context) |> elem(1)
    publish = Enum.find(snapshot.jobs, &(&1.job_key == "publish"))
    assert publish.status == :skipped

    assert {:ok, view, html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{publish.id}")
    assert has_element?(view, "#condition-explanation", "Condition did not match")
    assert html =~ "if: success"
  end

  test "shows immutable matrix values on pipeline and job views", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "matrix-live")

    matrix_job = %Robine.Workflows.Domain.Job{
      id: "test[otp=27]",
      base_id: "test",
      matrix_values: %{"otp" => "27"},
      image: "alpine:3.22",
      env: %{"ROBINE_MATRIX_OTP" => "27"},
      needs: [],
      steps: [%Robine.Workflows.Domain.Step{name: "Test", kind: :run, value: "true"}]
    }

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Matrix UI",
                 commit_sha: String.duplicate("9", 40),
                 jobs: %{matrix_job.id => matrix_job}
               },
               context
             )

    assert {:ok, pipeline_view, _html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    assert has_element?(pipeline_view, ".badge", "otp=27")

    snapshot = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context) |> elem(1)
    job = hd(snapshot.jobs)
    assert job.base_id == "test"
    assert job.matrix_values == %{"otp" => "27"}

    assert {:ok, job_view, _html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")
    assert has_element?(job_view, "#matrix-values", "otp=27")
    assert has_element?(job_view, "pre code", "robine run 'test[otp=27]'")
  end

  test "streams newly persisted stderr into a running job", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "live-job-logs")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Live logs",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 1, status: :preparing},
               context
             )

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 2, status: :running},
               context
             )

    snapshot = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context) |> elem(1)
    job = hd(snapshot.jobs)
    assert {:ok, view, _html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")
    assert has_element?(view, "#live-log-status")

    assert :ok =
             Pipelines.append_log_event(
               %{
                 attempt_id: attempt.id,
                 sequence: 1,
                 phase: :execution,
                 step_position: 1,
                 step_name: "Test",
                 status: :running,
                 duration_ms: 0,
                 stream: :stderr,
                 content: "compilation failed\n"
               },
               context
             )

    Phoenix.PubSub.broadcast(
      Robine.PubSub,
      "attempt-logs:#{attempt.id}",
      {:log_appended, attempt.id}
    )

    send(view.pid, :refresh_live_logs)
    assert render(view) =~ "compilation failed"
    assert has_element?(view, "[data-stream='stderr']")
    assert has_element?(view, "[data-stream='stderr'] .text-error", "[stderr]")
    assert has_element?(view, "#log-downloads a[href*='stream=stderr']")

    download_conn =
      get(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}/logs?stream=stderr")

    assert response(download_conn, 200) == "compilation failed\n"

    assert get_resp_header(download_conn, "content-disposition") ==
             [~s(attachment; filename="test-attempt-logs-stderr.log")]
  end

  test "renders terminal logs as stable retained history and ignores later stream notices", %{
    conn: conn
  } do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "terminal-job-logs")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Terminal logs",
                 commit_sha: String.duplicate("b", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 1, status: :preparing},
               context
             )

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{idempotency_token: attempt.idempotency_token, sequence: 2, status: :running},
               context
             )

    assert :ok =
             Pipelines.append_log_event(
               %{
                 attempt_id: attempt.id,
                 sequence: 1,
                 phase: :execution,
                 step_position: 1,
                 step_name: "Test",
                 status: :failed,
                 exit_code: 1,
                 duration_ms: 1_234,
                 stream: :system,
                 content: "terminal diagnostic"
               },
               context
             )

    assert {:ok, _attempt} =
             Pipelines.record_runner_event(
               %{
                 idempotency_token: attempt.idempotency_token,
                 sequence: 3,
                 status: :failed,
                 reason: :system_failure
               },
               context
             )

    snapshot = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context) |> elem(1)
    job = hd(snapshot.jobs)
    assert {:ok, view, _html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")

    assert has_element?(view, "#log-mode-description[data-log-mode='retained']")
    refute has_element?(view, "#live-log-status")
    refute has_element?(view, "#log-filter-form")
    refute has_element?(view, "#log-segments")

    assert has_element?(
             view,
             "#complete-log-viewer[phx-hook='RetainedLogViewer'][phx-update='ignore'][data-url*='view=inline']"
           )

    assert has_element?(view, "#log-downloads a[target='_blank']", "Open full log")

    assert :ok =
             Pipelines.append_log_event(
               %{
                 attempt_id: attempt.id,
                 sequence: 2,
                 phase: :execution,
                 step_position: 1,
                 step_name: "Test",
                 status: :running,
                 duration_ms: 9_999,
                 stream: :stdout,
                 content: "must not be streamed after terminal"
               },
               context
             )

    send(view.pid, {:log_appended, attempt.id})
    _ = :sys.get_state(view.pid)

    refute render(view) =~ "must not be streamed after terminal"

    inline_conn =
      get(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}/logs?view=inline")

    inline_log = response(inline_conn, 200)
    assert inline_log =~ "terminal diagnostic"
    assert inline_log =~ "must not be streamed after terminal"

    assert get_resp_header(inline_conn, "content-disposition") ==
             [~s(inline; filename="test-attempt-logs-combined.log")]
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
