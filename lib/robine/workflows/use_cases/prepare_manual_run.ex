defmodule Robine.Workflows.UseCases.PrepareManualRun do
  @moduledoc "Normalizes declared manual inputs and injects their reserved job environment."

  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.Domain.ManualInputPolicy

  @spec call(map()) :: {:ok, map()} | {:error, term()}
  def call(%{validated_workflow: %ValidatedWorkflow{workflow: workflow}, inputs: submitted})
      when is_map(submitted) do
    definitions = get_in(workflow.triggers, ["workflow_dispatch", "inputs"])

    if is_map(definitions) do
      with {:ok, inputs} <- ManualInputPolicy.normalize(definitions, submitted) do
        environment = Map.new(inputs, fn {id, value} -> {environment_name(id), value} end)

        jobs =
          Map.new(workflow.jobs, fn {id, job} ->
            {id, %{job | env: Map.merge(job.env, environment)}}
          end)

        {:ok, %{workflow: %{workflow | jobs: jobs}, inputs: inputs}}
      end
    else
      {:error, :manual_trigger_not_declared}
    end
  end

  def call(_input), do: {:error, :invalid_manual_run}

  defp environment_name(id), do: "ROBINE_INPUT_" <> String.upcase(id)
end
