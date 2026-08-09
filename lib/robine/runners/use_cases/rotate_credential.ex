defmodule Robine.Runners.UseCases.RotateCredential do
  @moduledoc "Rotates a runner credential with a bounded overlap for reconnects."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  @overlap_seconds 5 * 60

  def call(%{runner_id: runner_id}, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_binary(runner_id) do
    now = deps.clock.now()
    credential = deps.token_generator.generate("rrc")

    attributes = %{
      id: deps.id_generator.generate(),
      credential_digest: deps.digester.digest(credential),
      inserted_at: now
    }

    case deps.registry.rotate_credential(
           runner_id,
           attributes,
           now,
           DateTime.add(now, @overlap_seconds, :second),
           %{actor_id: actor_id, correlation_id: correlation_id}
         ) do
      :ok -> {:ok, %{runner_id: runner_id, credential: credential}}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
