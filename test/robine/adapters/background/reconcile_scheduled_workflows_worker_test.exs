defmodule Robine.Adapters.Background.ReconcileScheduledWorkflowsWorkerTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  alias Robine.Adapters.Background.ReconcileScheduledWorkflowsWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.Pipeline
  alias Robine.{Operations, Repositories}
  alias Robine.Runtime.Dependencies

  defmodule GitHub do
    @behaviour Robine.Repositories.Ports.GitHub
    @sha String.duplicate("7", 40)

    @impl true
    def default_branch_head(_repository), do: {:ok, %{branch: "main", sha: @sha}}

    @impl true
    def workflow_files(_repository, @sha) do
      {:ok,
       [
         %{
           path: ".robine-ci/workflows/hourly.yml",
           content: """
           version: 1
           name: Hourly
           on:
             schedule:
               - cron: "* * * * *"
           jobs:
             check:
               image: alpine:3.22
               steps:
                 - run: echo check
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
    @impl true
    def available_repositories, do: {:ok, []}
  end

  test "the minute adapter launches through the facade and updates scheduler health" do
    previous = Application.fetch_env!(:robine, :github_adapter)
    Application.put_env(:robine, :github_adapter, GitHub)
    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous) end)

    context = Dependencies.context(%{id: "admin", role: :administrator}, "schedule-worker-test")

    assert {:ok, _repository} =
             Repositories.register_github_repository(
               %{provider_id: 72_001, installation_id: 72, full_name: "acme/hourly"},
               context
             )

    assert :ok = ReconcileScheduledWorkflowsWorker.perform(%Oban.Job{id: 72_001})

    pipeline = Repo.one!(Pipeline)
    assert pipeline.trigger == "schedule"
    assert pipeline.actor == "system:scheduler"
    assert pipeline.scheduled_for.second == 0

    assert {:ok, health} = Operations.health(%{}, context)
    assert health.checks.scheduler.status == :ok
    assert health.checks.scheduler.cursor_age_seconds in 0..120
    assert health.checks.scheduler.last_failure == nil
  end

  test "Oban config invokes schedule reconciliation every minute" do
    source = File.read!("config/config.exs")

    assert source =~
             ~s({"* * * * *", Robine.Adapters.Background.ReconcileScheduledWorkflowsWorker})
  end
end
