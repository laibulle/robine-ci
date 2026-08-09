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
        %{id: "system:source-control-delivery", role: :administrator},
        "source-control:#{delivery_id}"
      )

    Log.event(:info, "source_control.delivery.processing", %{
      correlation_id: context.correlation_id,
      delivery_id: delivery_id,
      outcome: :started
    })

    result = Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    worker_result =
      case result do
        {:ok, %{pipeline_ids: pipeline_ids} = completed} ->
          Enum.each(pipeline_ids, fn pipeline_id ->
            Log.event(:info, "source_control.delivery.pipeline_created", %{
              correlation_id: context.correlation_id,
              delivery_id: delivery_id,
              pipeline_id: pipeline_id,
              outcome: :created
            })
          end)

          {:ok, Map.get(completed, :provider, :unknown)}

        {:ok, ignored} ->
          Log.event(:info, "source_control.delivery.completed", %{
            correlation_id: context.correlation_id,
            delivery_id: delivery_id,
            outcome: if(Map.has_key?(ignored, :ignored), do: :ignored, else: :ok)
          })

          {:ok, Map.get(ignored, :provider, :unknown)}

        {:error, :not_found} ->
          Log.event(:warning, "source_control.delivery.completed", %{
            correlation_id: context.correlation_id,
            delivery_id: delivery_id,
            outcome: :not_found
          })

          {:cancel, :delivery_not_found}

        {:error, reason} ->
          Log.event(:error, "source_control.delivery.completed", %{
            correlation_id: context.correlation_id,
            delivery_id: delivery_id,
            outcome: :error
          })

          {:error, reason}
      end

    provider = worker_provider(worker_result)

    :telemetry.execute(
      [:robine, :source_control, :delivery],
      %{count: 1, duration: System.monotonic_time() - started},
      %{provider: provider, outcome: delivery_outcome(worker_result)}
    )

    if provider == :github do
      :telemetry.execute(
        [:robine, :github, :delivery],
        %{count: 1, duration: System.monotonic_time() - started},
        %{outcome: delivery_outcome(worker_result)}
      )
    end

    normalize_worker_result(worker_result)
  end

  defp delivery_outcome({:ok, _provider}), do: :ok
  defp delivery_outcome({:cancel, _reason}), do: :cancelled
  defp delivery_outcome({:error, _reason}), do: :error

  defp worker_provider({:ok, provider}) when provider in [:github, :gitlab, :forgejo],
    do: provider

  defp worker_provider(_result), do: :unknown
  defp normalize_worker_result({:ok, _provider}), do: :ok
  defp normalize_worker_result(result), do: result
end
