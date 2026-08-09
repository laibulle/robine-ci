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
                   source: "version: 1\nname: CI\n"
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

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
