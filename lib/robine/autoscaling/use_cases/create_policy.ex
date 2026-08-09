defmodule Robine.Autoscaling.UseCases.CreatePolicy do
  @moduledoc "Creates one validated, audited autoscaling policy."
  alias Robine.Autoscaling.Dependencies
  alias Robine.Autoscaling.Domain.Policy
  alias Robine.ExecutionContext

  def call(input, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{autoscaling: %Dependencies{} = deps}
      }) do
    now = deps.clock.now()

    with {:ok, policy} <-
           Policy.new(
             input
             |> Map.put(:id, deps.id_generator.generate())
             |> Map.put(:inserted_at, now)
             |> Map.put(:updated_at, now)
           ),
         :ok <-
           deps.repository.insert_policy(policy, %{
             actor_id: actor_id,
             correlation_id: correlation_id
           }) do
      {:ok, Map.from_struct(policy)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
