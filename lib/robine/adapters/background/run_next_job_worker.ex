defmodule Robine.Adapters.Background.RunNextJobWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 5]

  alias Robine.Execution
  alias Robine.Execution.Contracts.{Specification, Step}
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies
  alias Robine.Secrets

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    context =
      Dependencies.context(
        %{id: "system:local-runner", role: :administrator},
        "local-runner:#{Ecto.UUID.generate()}"
      )

    case Pipelines.claim_next_job(%{}, context) do
      {:ok, attempt} -> execute(attempt, context)
      {:error, :none} -> :ok
      {:error, :capacity} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(attempt, context) do
    with {:ok, _preparing} <- record(attempt, 1, :preparing, nil, context),
         {:ok, raw_specification} <-
           Pipelines.job_execution(%{idempotency_token: attempt.idempotency_token}, context),
         {:ok, specification} <- specification(raw_specification, context),
         {:ok, _running} <- record(attempt, 2, :running, nil, context),
         {:ok, result} <- Execution.run_job(%{specification: specification}, context),
         {:ok, _terminal} <- record_result(attempt, result, context) do
      enqueue_next()
    else
      {:error, reason} ->
        _ = record(attempt, next_sequence(attempt), :failed, :system_failure, context)
        {:error, reason}
    end
  end

  defp specification(raw, context) do
    with image when is_binary(image) <- raw["image"],
         steps when is_list(steps) and steps != [] <- raw["steps"],
         {:ok, secret_values} <- resolve_secrets(raw, context) do
      {:ok,
       %Specification{
         version: 1,
         attempt_id: raw["attempt_id"],
         image: image,
         workspace: "/workspace",
         shell: raw["shell"] || "/bin/sh",
         timeout_ms: raw["timeout_ms"] || 1_200_000,
         env: raw["env"] || %{},
         secrets: secret_values,
         metadata: %{"idempotency_token" => raw["idempotency_token"]},
         steps: Enum.map(steps, &step/1)
       }}
    else
      _ -> {:error, :invalid_persisted_execution_specification}
    end
  end

  defp resolve_secrets(%{"secret_names" => []}, _context), do: {:ok, %{}}

  defp resolve_secrets(%{"secret_names" => names} = raw, context) when is_list(names) do
    Secrets.resolve_secrets(%{repository_id: raw["repository_id"], names: names}, context)
  end

  defp resolve_secrets(_raw, _context), do: {:ok, %{}}

  defp step(raw) do
    %Step{
      name: raw["name"],
      kind: kind(raw["kind"]),
      value: raw["value"],
      with: raw["with"] || %{}
    }
  end

  defp kind(:run), do: :run
  defp kind("run"), do: :run
  defp kind(:builtin), do: :builtin
  defp kind("builtin"), do: :builtin
  defp kind(_unknown), do: :invalid

  defp record_result(attempt, %{status: :succeeded}, context),
    do: record(attempt, 3, :succeeded, nil, context)

  defp record_result(attempt, %{status: :failed, reason: reason}, context),
    do: record(attempt, 3, :failed, reason, context)

  defp record(attempt, sequence, status, reason, context) do
    Pipelines.record_runner_event(
      %{
        idempotency_token: attempt.idempotency_token,
        sequence: sequence,
        status: status,
        reason: reason
      },
      context
    )
  end

  defp next_sequence(attempt) do
    case attempt.last_sequence do
      sequence when sequence < 1 -> 1
      sequence when sequence < 2 -> 2
      _sequence -> 3
    end
  end

  defp enqueue_next do
    case Oban.insert(new(%{})) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
