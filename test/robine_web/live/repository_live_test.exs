defmodule RobineWeb.RepositoryLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Repositories
  alias Robine.Adapters.Persistence.Postgres.Schemas.{GitHubRepository, Job, Pipeline, User}
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  defmodule RepositoryDiscoveryGitHub do
    @behaviour Robine.Repositories.Ports.GitHub

    @impl true
    def available_repositories do
      {:ok,
       [
         %{
           provider_id: 73_001,
           installation_id: 42,
           full_name: "acme/discovered",
           private: true
         }
       ]}
    end

    @impl true
    def workflow_files(_repository, _sha), do: {:ok, []}
    @impl true
    def source_files(_repository, _sha), do: {:ok, []}
    @impl true
    def upsert_check(_repository, _check), do: {:ok, 1}
    @impl true
    def installation_permissions(_repository), do: {:ok, %{}}
  end

  defmodule ManualWorkflowGitHub do
    @behaviour Robine.Repositories.Ports.GitHub

    @sha String.duplicate("c", 40)

    @impl true
    def available_repositories, do: {:ok, []}

    @impl true
    def default_branch_head(_repository), do: {:ok, %{branch: "main", sha: @sha}}

    @impl true
    def workflow_files(_repository, @sha) do
      {:ok,
       [
         %{
           path: ".robine-ci/workflows/release.yml",
           content: """
           version: 1
           name: Release
           on:
             schedule:
               - cron: "0 2 * * *"
             workflow_dispatch:
               inputs:
                 environment:
                   description: Deployment target
                   type: choice
                   required: true
                   options: [staging, production]
                 version:
                   type: string
                   required: true
                 dry_run:
                   type: boolean
                   default: true
           jobs:
             release:
               image: alpine:3.22
               steps:
                 - run: echo release
           """
         }
       ]}
    end

    @impl true
    def source_files(_repository, _sha), do: {:ok, []}
    @impl true
    def upsert_check(_repository, _check), do: {:ok, 1}
    @impl true
    def installation_permissions(_repository), do: {:ok, %{}}
  end

  test "browses a trusted repository and manages write-only secrets", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "repository-live")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 91_919_191, installation_id: 42, full_name: "acme/widget"},
               context
             )

    assert {:ok, index, html} = live(conn, ~p"/repositories")
    assert html =~ "acme/widget"
    assert has_element?(index, "#repository-#{repository.id}")

    assert {:ok, show, html} = live(conn, ~p"/repositories/#{repository.id}")
    assert html =~ "No valid workflow has run yet"
    assert html =~ "Manage secrets"
    assert html =~ "Metadata read, Contents read, Checks write"
    assert has_element?(show, "#check-github-installation", "Check permissions")

    assert {:ok, secrets, html} = live(conn, ~p"/repositories/#{repository.id}/secrets")
    assert html =~ "write-only"

    html =
      secrets
      |> form("#secret-form", %{"name" => "REGISTRY_TOKEN", "value" => "super-secret-value"})
      |> render_submit()

    assert html =~ "REGISTRY_TOKEN"
    refute html =~ "super-secret-value"
  end

  test "discovers GitHub App access and trusts only an exact server-verified selection", %{
    conn: conn
  } do
    previous_adapter = Application.fetch_env!(:robine, :github_adapter)
    Application.put_env(:robine, :github_adapter, RepositoryDiscoveryGitHub)
    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous_adapter) end)

    conn = signed_in_conn(conn)
    assert {:ok, view, html} = live(conn, ~p"/repositories")
    assert html =~ "No provider access has been queried"

    html = view |> element("#discover-github-repositories") |> render_click()
    assert html =~ "acme/discovered"
    assert html =~ "Installation 42"

    html =
      view
      |> element("#available-repository-73001 button")
      |> render_click(%{
        "provider_id" => "999",
        "installation_id" => "42",
        "full_name" => "acme/discovered"
      })

    assert html =~ "GitHub no longer grants"
    refute html =~ "is now trusted"

    html =
      view
      |> element("#available-repository-73001 button")
      |> render_click()

    assert html =~ "acme/discovered is now trusted"
    assert has_element?(view, "[id^='repository-']")
    refute has_element?(view, "#available-repository-73001")
  end

  test "viewer route and forged-event boundaries remain read-only", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "viewer-boundary")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 80_001, installation_id: 8, full_name: "acme/read-only"},
               context
             )

    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :viewer) |> Repo.update!()

    assert {:error, {:redirect, %{to: "/pipelines"}}} =
             live(conn, ~p"/repositories/#{repository.id}/secrets")

    assert {:ok, index, index_html} = live(conn, ~p"/repositories")
    refute index_html =~ "Refresh installations"
    assert render_hook(index, "discover", %{}) =~ "Only administrators can connect repositories."

    assert render_hook(index, "trust", %{
             "provider_id" => "80_002",
             "installation_id" => "8",
             "full_name" => "acme/forged"
           }) =~ "The repository could not be trusted."

    assert Repo.aggregate(GitHubRepository, :count) == 1

    assert {:ok, show, show_html} = live(conn, ~p"/repositories/#{repository.id}")
    refute show_html =~ "Check permissions"

    assert render_hook(show, "check-github-installation", %{}) =~
             "You do not have permission to check GitHub installations."

    assert render_hook(show, "launch-manual-workflow", %{
             "workflow_path" => ".robine-ci/workflows/release.yml",
             "request_id" => "forged-viewer-request",
             "inputs" => %{"environment" => "production", "version" => "1.0.0"}
           }) =~ "You do not have permission to launch workflows."

    assert Repo.aggregate(Pipeline, :count) == 0
  end

  test "discovers and launches a manual workflow at the displayed immutable revision", %{
    conn: conn
  } do
    previous_adapter = Application.fetch_env!(:robine, :github_adapter)
    Application.put_env(:robine, :github_adapter, ManualWorkflowGitHub)
    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous_adapter) end)

    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "manual-live")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 90_001, installation_id: 9, full_name: "acme/manual"},
               context
             )

    assert {:ok, show, html} = live(conn, ~p"/repositories/#{repository.id}")
    assert html =~ "No source-control request has been made"

    html = show |> element("#discover-manual-workflows") |> render_click()
    assert html =~ String.duplicate("c", 40)
    assert html =~ "Release"
    assert has_element?(show, "select[name='inputs[environment]']")
    assert has_element?(show, "input[name='inputs[version]']")

    invalid_html =
      render_hook(show, "launch-manual-workflow", %{
        "workflow_path" => ".robine-ci/workflows/release.yml",
        "request_id" => "invalid-live-input",
        "inputs" => %{"environment" => "invalid", "version" => "2.4.0"}
      })

    assert invalid_html =~ "This input is not an allowed choice."
    assert has_element?(show, "#manual-input-environment-error[role='alert']")

    form_id = "manual-workflow-#{:erlang.phash2(".robine-ci/workflows/release.yml")}"

    show
    |> form("##{form_id}", %{
      "inputs" => %{
        "environment" => "production",
        "version" => "2.4.0",
        "dry_run" => "false"
      }
    })
    |> render_submit()

    pipeline = Repo.one!(Pipeline)
    assert_redirect(show, ~p"/pipelines/#{pipeline.id}")
    assert pipeline.commit_sha == String.duplicate("c", 40)
    assert pipeline.trigger == "workflow_dispatch"

    assert pipeline.inputs == %{
             "environment" => "production",
             "version" => "2.4.0",
             "dry_run" => "false"
           }

    assert {:ok, pipeline_view, pipeline_html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    assert has_element?(pipeline_view, "#manual-inputs")
    assert pipeline_html =~ "production"
    assert pipeline_html =~ "2.4.0"

    job = Repo.one!(Job)

    assert {:ok, job_view, job_html} =
             live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")

    assert has_element?(job_view, "#manual-inputs")
    assert job_html =~ "--input &#39;environment=production&#39;"
    assert job_html =~ "--input &#39;version=2.4.0&#39;"

    assert {:ok, schedule_show, _html} = live(conn, ~p"/repositories/#{repository.id}")
    schedule_html = schedule_show |> element("#discover-scheduled-workflows") |> render_click()
    assert schedule_html =~ String.duplicate("c", 40)
    assert schedule_html =~ "0 2 * * *"
    assert has_element?(schedule_show, "#schedule-workflow-head")
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
