defmodule Robine.Adapters.Background.ProcessGitHubDeliveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:args], keys: [:delivery_id]]

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies
  alias Robine.Adapters.Background.SyncGitHubChecksWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    context =
      Dependencies.context(
        %{id: "system:github-delivery", role: :administrator},
        "github:#{delivery_id}"
      )

    case Repositories.process_github_delivery(%{delivery_id: delivery_id}, context) do
      {:ok, %{pipeline_ids: pipeline_ids}} -> enqueue_checks(pipeline_ids)
      {:ok, _result} -> :ok
      {:error, :not_found} -> {:cancel, :delivery_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_checks(pipeline_ids) do
    Enum.reduce_while(pipeline_ids, :ok, fn pipeline_id, :ok ->
      case %{pipeline_id: pipeline_id} |> SyncGitHubChecksWorker.new() |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
