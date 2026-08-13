defmodule Robine.Adapters.Background.ReconcileGitHubChecksWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 240]

  alias Robine.Pipelines
  alias Robine.Repositories
  alias Robine.Adapters.Background.TenantJob

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    TenantJob.run(
      job,
      __MODULE__,
      "github-check-reconciliation:#{Ecto.UUID.generate()}",
      fn context ->
        with {:ok, pipelines} <- Pipelines.list_pipelines(%{limit: 100}, context) do
          Enum.reduce_while(pipelines, :ok, fn pipeline, :ok ->
            case Repositories.sync_github_checks(%{pipeline_id: pipeline.id}, context) do
              {:ok, _count} -> {:cont, :ok}
              {:error, :not_found} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end
      end
    )
  end
end
