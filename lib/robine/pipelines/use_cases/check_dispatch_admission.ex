defmodule Robine.Pipelines.UseCases.CheckDispatchAdmission do
  @moduledoc "Reports whether local dispatch admission currently accepts new work."

  alias Robine.ExecutionContext
  alias Robine.Pipelines.Dependencies

  def call(_input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{pipelines: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer, :viewer] do
    case deps.admission.check() do
      :ok -> {:ok, :available}
      {:error, reason} -> {:ok, {:blocked, reason}}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
