defmodule RobineWeb.PipelineLiveTest do
  use RobineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Robine.Pipelines
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
                 jobs: %{"build" => %{needs: []}, "test" => %{needs: ["build"]}}
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

    assert {:ok, _job_view, job_html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")
    assert job_html =~ "robine run test"
    assert job_html =~ "CI-only inputs"
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
