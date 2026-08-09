defmodule Robine.Pipelines.UseCases.ReconcileRunnerAttempts do
  @moduledoc "Reconciles a reconnecting runner's claimed attempts with durable lease ownership."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(%{active_attempt_ids: reported}, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        dependencies: %{pipelines: %Dependencies{job_repository: repository}}
      })
      when is_list(reported) and length(reported) <= 64 and is_atom(repository) do
    if Enum.all?(reported, &(is_binary(&1) and byte_size(&1) <= 128)) do
      with {:ok, assigned} <- repository.list_active_attempts_for_runner(runner_id) do
        assigned_ids = MapSet.new(assigned, & &1.id)
        reported_ids = MapSet.new(reported)

        {:ok,
         %{
           resume:
             Enum.map(assigned, &%{attempt_id: &1.id, acknowledged_sequence: &1.last_sequence}),
           lease_lost:
             reported_ids
             |> MapSet.difference(assigned_ids)
             |> MapSet.to_list()
             |> Enum.sort()
         }}
      end
    else
      {:error, :invalid_active_attempts}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_active_attempts}
end
