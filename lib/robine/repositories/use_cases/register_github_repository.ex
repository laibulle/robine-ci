defmodule Robine.Repositories.UseCases.RegisterGitHubRepository do
  @moduledoc "Registers one explicitly trusted GitHub App repository."
  alias Robine.ExecutionContext
  alias Robine.Repositories.Contracts.RepositoryView
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.Repository

  @spec call(map(), ExecutionContext.t()) :: {:ok, RepositoryView.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = deps}
      }) do
    with {:ok, values} <- validate(input),
         now = DateTime.truncate(deps.clock.now(), :microsecond),
         repository =
           struct!(
             Repository,
             Map.merge(values, %{
               id: deps.id_generator.generate(),
               trusted: true,
               inserted_at: now
             })
           ),
         :ok <- deps.repository.upsert_repository(repository) do
      {:ok, %RepositoryView{id: repository.id, full_name: repository.full_name, trusted: true}}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp validate(input) do
    provider_id = Map.get(input, :provider_id)
    installation_id = Map.get(input, :installation_id)
    full_name = Map.get(input, :full_name)

    case {provider_id, installation_id, full_name && String.split(full_name, "/", parts: 2)} do
      {provider_id, installation_id, [owner, name]}
      when is_integer(provider_id) and is_integer(installation_id) and owner != "" and name != "" ->
        {:ok,
         %{
           provider_id: provider_id,
           installation_id: installation_id,
           owner: owner,
           name: name,
           full_name: full_name
         }}

      _ ->
        {:error, {:invalid_repository, :metadata}}
    end
  end
end
