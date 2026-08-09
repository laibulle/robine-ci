defmodule Robine.Adapters.Background.ReconcileGitHubChecksWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 240]

  alias Robine.Pipelines
  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    context =
      Dependencies.context(
        %{id: "system:github-check-reconciler", role: :administrator},
        "github-check-reconciliation:#{Ecto.UUID.generate()}"
      )

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
end
