defmodule Robine.Adapters.Background.PruneRetentionWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 3_000]

  alias Robine.Operations
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) do
    context =
      Dependencies.context(
        %{id: "system:retention", role: :administrator},
        "retention:#{id}"
      )

    case Operations.prune_retention(%{}, context) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
