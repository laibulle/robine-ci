defmodule Robine.Execution.UseCases.RunJob do
  @moduledoc "Validates and executes one normalized job through the configured runner port."

  alias Robine.Execution.Contracts.Specification
  alias Robine.Execution.Dependencies
  alias Robine.Execution.Domain.SpecificationValidator
  alias Robine.ExecutionContext

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, Robine.Execution.Contracts.Result.t()} | {:error, term()}
  def call(%{specification: %Specification{} = specification} = input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{execution: %Dependencies{} = dependencies}
      })
      when role in [:administrator, :maintainer] do
    with :ok <- SpecificationValidator.validate(specification) do
      on_output = Map.get(input, :on_output, fn _event -> :ok end)

      on_builtin =
        Map.get(input, :on_builtin, fn event ->
          {:error, {:unsupported_builtin, event.builtin}}
        end)

      cancel_requested = Map.get(input, :cancel_requested, fn -> false end)

      callback = fn
        %{type: :builtin} = event -> on_builtin.(event)
        event -> on_output.(event)
      end

      if is_function(on_output, 1) and is_function(on_builtin, 1) and
           is_function(cancel_requested, 0),
         do: dependencies.runner.run(specification, callback, cancel_requested),
         else: {:error, {:invalid_specification, :on_output}}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
