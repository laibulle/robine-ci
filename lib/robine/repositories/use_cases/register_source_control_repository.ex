defmodule Robine.Repositories.UseCases.RegisterSourceControlRepository do
  @moduledoc "Registers one server-verified trusted source-control repository identity."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Contracts.RepositoryView
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.Repository

  @providers [:github, :gitlab, :forgejo]

  @spec call(map(), ExecutionContext.t()) :: {:ok, RepositoryView.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = dependencies}
      }) do
    with {:ok, values} <- validate(input),
         repository <-
           struct!(
             Repository,
             Map.merge(values, %{
               id: dependencies.id_generator.generate(),
               trusted: true,
               inserted_at: DateTime.truncate(dependencies.clock.now(), :microsecond)
             })
           ),
         :ok <- dependencies.repository.upsert_repository(repository) do
      {:ok, view(repository)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp validate(input) when is_map(input) do
    provider = Map.get(input, :provider)
    provider_instance = Map.get(input, :provider_instance, "default")
    provider_id = Map.get(input, :provider_id)
    installation_id = Map.get(input, :installation_id, 0)
    full_name = Map.get(input, :full_name)

    case {provider, provider_instance, provider_id, installation_id,
          full_name && String.split(full_name, "/", parts: 2)} do
      {provider, instance, provider_id, installation_id, [owner, name]}
      when provider in @providers and is_binary(instance) and byte_size(instance) in 1..64 and
             is_integer(provider_id) and provider_id > 0 and is_integer(installation_id) and
             installation_id >= 0 and owner != "" and name != "" and byte_size(full_name) <= 255 ->
        {:ok,
         %{
           provider: provider,
           provider_instance: instance,
           provider_id: provider_id,
           installation_id: installation_id,
           owner: owner,
           name: name,
           full_name: full_name
         }}

      _invalid ->
        {:error, {:invalid_repository, :metadata}}
    end
  end

  defp validate(_input), do: {:error, {:invalid_repository, :metadata}}

  defp view(repository) do
    %RepositoryView{
      id: repository.id,
      provider: repository.provider,
      provider_instance: repository.provider_instance,
      full_name: repository.full_name,
      trusted: repository.trusted
    }
  end
end
