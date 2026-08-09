defmodule Robine.Runners.UseCases.CreateEnrollmentToken do
  @moduledoc "Creates one short-lived runner enrollment secret for an administrator."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  @lifetime_seconds 15 * 60

  def call(_input, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{runners: %Dependencies{} = deps}
      }) do
    now = deps.clock.now()
    token = deps.token_generator.generate("rbe")
    expires_at = DateTime.add(now, @lifetime_seconds, :second)
    id = deps.id_generator.generate()

    attributes = %{
      id: id,
      token_digest: deps.digester.digest(token),
      expires_at: expires_at,
      created_by: actor_id,
      inserted_at: now,
      audit: %{actor_id: actor_id, correlation_id: correlation_id}
    }

    case deps.registry.create_enrollment(attributes) do
      :ok -> {:ok, %{id: id, token: token, expires_at: expires_at}}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
