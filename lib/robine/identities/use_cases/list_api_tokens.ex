defmodule Robine.Identities.UseCases.ListApiTokens do
  @moduledoc "Lists secret-free API token metadata for one repository."

  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, [Robine.Identities.Domain.ApiToken.t()]} | {:error, term()}
  def call(%{repository_id: repository_id}, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{identities: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] do
    if valid_uuid?(repository_id),
      do: deps.repository.list_api_tokens(repository_id),
      else: {:error, {:invalid_api_token, :repository_id}}
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
end
