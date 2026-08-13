defmodule Robine.Adapters.Background.PruneRetentionWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 3_000]

  alias Robine.Operations
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{id: id} = job) do
    TenantJob.run(job, __MODULE__, "retention:#{id}", fn context ->
      case Operations.prune_retention(%{}, context) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
