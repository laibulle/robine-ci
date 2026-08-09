defmodule Robine.Adapters.Background.ProcessGitHubDeliveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:args], keys: [:delivery_id]]

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    context =
      Dependencies.context(
        %{id: "system:github-delivery", role: :administrator},
        "github:#{delivery_id}"
      )

    case Repositories.process_github_delivery(%{delivery_id: delivery_id}, context) do
      {:ok, %{pipeline_ids: _pipeline_ids}} -> :ok
      {:ok, _result} -> :ok
      {:error, :not_found} -> {:cancel, :delivery_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
