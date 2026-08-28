defmodule Robine.Identities.UseCases.ListApiTokens do
  @moduledoc "Lists secret-free metadata for instance-global API tokens."

  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, [Robine.Identities.Domain.ApiToken.t()]} | {:error, term()}
  def call(_input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{identities: %Dependencies{} = deps}
      }) do
    deps.repository.list_api_tokens()
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
