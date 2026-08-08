defmodule Robine.Execution.UseCases.RunJob do
  @moduledoc "Validates and executes one normalized job through the configured runner port."

  alias Robine.Execution.Contracts.Specification
  alias Robine.Execution.Dependencies
  alias Robine.Execution.Domain.SpecificationValidator
  alias Robine.ExecutionContext

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, Robine.Execution.Contracts.Result.t()} | {:error, term()}
  def call(%{specification: %Specification{} = specification}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{execution: %Dependencies{} = dependencies}
      })
      when role in [:administrator, :maintainer] do
    with :ok <- SpecificationValidator.validate(specification) do
      dependencies.runner.run(specification)
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
