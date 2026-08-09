defmodule Robine.Adapters.Background.SyncGitHubChecksWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 8,
    unique: [period: 5, fields: [:args], keys: [:pipeline_id]]

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_id" => pipeline_id}}) do
    context =
      Dependencies.context(
        %{id: "system:github-checks", role: :administrator},
        "github-checks:#{pipeline_id}"
      )

    case Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
