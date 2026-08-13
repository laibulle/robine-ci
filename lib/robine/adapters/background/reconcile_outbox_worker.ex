defmodule Robine.Adapters.Background.ReconcileOutboxWorker do
  @moduledoc false
  use Oban.Worker, queue: :outbox, max_attempts: 5, unique: [period: 50]

  alias Robine.Pipelines
  alias Robine.Adapters.Background.RunNextJobWorker
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    TenantJob.run(job, __MODULE__, "outbox-reconciliation:#{Ecto.UUID.generate()}", fn context ->
      with {:ok, count} <- Pipelines.reconcile_outbox(%{limit: 100}, context),
           {:ok, _job} <-
             %{} |> TenantJob.put_tenant() |> RunNextJobWorker.new() |> Oban.insert() do
        :telemetry.execute([:robine, :outbox, :reconciliation], %{count: count}, %{})
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
