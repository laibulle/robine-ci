defmodule Robine.Adapters.Background.ProcessGitHubDeliveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:args], keys: [:delivery_id]]

  alias Robine.Repositories
  alias Robine.Observability.Log
  alias Robine.Runtime.Dependencies

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    started = System.monotonic_time()

    context =
      Dependencies.context(
        %{id: "system:github-delivery", role: :administrator},
        "github:#{delivery_id}"
      )

    Log.event(:info, "github.delivery.processing", %{
      correlation_id: context.correlation_id,
      delivery_id: delivery_id,
      outcome: :started
    })

    result = Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    worker_result =
      case result do
        {:ok, %{pipeline_ids: pipeline_ids}} ->
          Enum.each(pipeline_ids, fn pipeline_id ->
            Log.event(:info, "github.delivery.pipeline_created", %{
              correlation_id: context.correlation_id,
              delivery_id: delivery_id,
              pipeline_id: pipeline_id,
              outcome: :created
            })
          end)

          :ok

        {:ok, ignored} ->
          Log.event(:info, "github.delivery.completed", %{
            correlation_id: context.correlation_id,
            delivery_id: delivery_id,
            outcome: if(Map.has_key?(ignored, :ignored), do: :ignored, else: :ok)
          })

          :ok

        {:error, :not_found} ->
          Log.event(:warning, "github.delivery.completed", %{
            correlation_id: context.correlation_id,
            delivery_id: delivery_id,
            outcome: :not_found
          })

          {:cancel, :delivery_not_found}

        {:error, reason} ->
          Log.event(:error, "github.delivery.completed", %{
            correlation_id: context.correlation_id,
            delivery_id: delivery_id,
            outcome: :error
          })

          {:error, reason}
      end

    :telemetry.execute(
      [:robine, :github, :delivery],
      %{count: 1, duration: System.monotonic_time() - started},
      %{outcome: delivery_outcome(worker_result)}
    )

    worker_result
  end

  defp delivery_outcome(:ok), do: :ok
  defp delivery_outcome({:cancel, _reason}), do: :cancelled
  defp delivery_outcome({:error, _reason}), do: :error
end
