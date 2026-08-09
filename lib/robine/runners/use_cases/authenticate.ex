defmodule Robine.Runners.UseCases.Authenticate do
  @moduledoc "Authenticates a machine identity using constant-time credential comparison."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies

  def call(%{runner_id: runner_id, credential: credential}, %ExecutionContext{
        correlation_id: correlation_id,
        dependencies: %{runners: %Dependencies{} = deps}
      })
      when is_binary(runner_id) and is_binary(credential) do
    now = deps.clock.now()

    {runner, digests} = authentication_material(runner_id, now, deps)
    matched = constant_time_match?(credential, digests, deps.digester)

    result =
      if (valid_secret_shape?(credential) and runner) && matched do
        case deps.registry.record_authentication(runner.id, now) do
          :ok ->
            {:ok,
             %{
               runner_id: runner.id,
               name: runner.name,
               admin_state: runner.admin_state
             }}

          {:error, _reason} ->
            {:error, :unauthorized}
        end
      else
        {:error, :unauthorized}
      end

    if result == {:error, :unauthorized} do
      :ok =
        deps.registry.audit_authentication_failure(runner_id, now, %{
          actor_id: "remote-runner",
          correlation_id: correlation_id
        })
    end

    result
  end

  def call(_input, %ExecutionContext{}), do: {:error, :unauthorized}

  defp authentication_material(runner_id, now, deps) do
    case deps.registry.authentication_candidates(runner_id, now) do
      {:ok, runner, [_digest | _rest] = digests} ->
        {runner, digests}

      {:ok, _runner, []} ->
        {nil, [deps.digester.digest("invalid-runner-credential-sentinel")]}

      {:error, :not_found} ->
        {nil, [deps.digester.digest("invalid-runner-credential-sentinel")]}
    end
  end

  defp constant_time_match?(credential, digests, digester) do
    Enum.reduce(digests, false, fn digest, matched ->
      digester.verify(credential, digest) or matched
    end)
  end

  defp valid_secret_shape?("rrc_" <> encoded) when byte_size(encoded) >= 43, do: true
  defp valid_secret_shape?(_secret), do: false
end
