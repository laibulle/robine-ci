defmodule Robine.Adapters.Background.ReconcileOutboxWorkerTest do
  use Robine.DataCase, async: true
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.{ReconcileOutboxWorker, RunNextJobWorker}
  alias Robine.Repo

  test "periodic reconciliation also recovers queued-job dispatch" do
    assert :ok = perform_job(ReconcileOutboxWorker, %{})

    assert Repo.exists?(
             from job in Oban.Job,
               where: job.worker == ^inspect(RunNextJobWorker) and job.state == "available"
           )
  end
end
