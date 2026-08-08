defmodule Robine.Pipelines.UseCases.ReconcileExpiredLeasesTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.{Attempt, Pipeline}
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  test "expired active attempts fail as runner_lost exactly once" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "lease-test")

    {:ok, pipeline} =
      Pipelines.create_pipeline(
        %{
          repository_id: Ecto.UUID.generate(),
          workflow_name: "CI",
          commit_sha: String.duplicate("f", 40),
          jobs: %{"test" => %{needs: []}}
        },
        context
      )

    outbox_job = Repo.one!(from job in Oban.Job, where: job.queue == "outbox")
    :ok = perform_job(OutboxDeliveryWorker, outbox_job.args)
    {:ok, attempt} = Pipelines.claim_next_job(%{lease_seconds: 1}, context)

    Repo.get!(Attempt, attempt.id)
    |> Ecto.Changeset.change(lease_expires_at: ~U[2020-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, 1} = Pipelines.reconcile_expired_leases(%{}, context)
    assert Repo.get!(Attempt, attempt.id).result_reason == :runner_lost
    assert Repo.get!(Pipeline, pipeline.id).status == :failed
    assert {:ok, 0} = Pipelines.reconcile_expired_leases(%{}, context)
  end
end
