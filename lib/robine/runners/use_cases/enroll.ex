defmodule Robine.Runners.UseCases.Enroll do
  @moduledoc "Atomically exchanges a single-use enrollment token for a runner credential."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies
  alias Robine.Runners.Domain.Runner

  def call(%{token: token, name: name}, %ExecutionContext{
        correlation_id: correlation_id,
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_binary(token) and is_binary(name) do
    now = deps.clock.now()
    credential = deps.token_generator.generate("rrc")

    with true <- valid_secret_shape?(token),
         {:ok, runner} <-
           Runner.new(%{id: deps.id_generator.generate(), name: name, inserted_at: now}),
         {:ok, enrolled} <-
           deps.registry.consume_enrollment(
             deps.digester.digest(token),
             now,
             runner,
             %{
               id: deps.id_generator.generate(),
               credential_digest: deps.digester.digest(credential),
               inserted_at: now
             },
             %{actor_id: "runner-enrollment", correlation_id: correlation_id}
           ) do
      {:ok, %{runner_id: enrolled.id, credential: credential}}
    else
      false -> {:error, :invalid_enrollment_token}
      {:error, :invalid_runner} -> {:error, :invalid_runner}
      {:error, _reason} -> {:error, :invalid_enrollment_token}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_enrollment_request}

  defp valid_secret_shape?("rbe_" <> encoded) when byte_size(encoded) >= 43, do: true
  defp valid_secret_shape?(_secret), do: false
end
