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
    assert has_element?(index, "#pipeline-#{pipeline.id}", "CI")

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

  test "shows trigger, actor, duration, runner phase, and infrastructure failure", %{conn: conn} do
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
                 step_position: 1,
                 step_name: "Test",
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

    assert {:ok, _view, html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    assert html =~ "Infrastructure failure"
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
    assert {:ok, _job_view, job_html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")
    assert job_html =~ ~s(id="phase-image_acquisition")
    assert job_html =~ ~s(id="phase-execution")
    assert job_html =~ ~s(id="step-1")
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

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
