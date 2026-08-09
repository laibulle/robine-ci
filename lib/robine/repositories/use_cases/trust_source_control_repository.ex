defmodule Robine.Repositories.UseCases.TrustSourceControlRepository do
  @moduledoc "Trusts a repository only after exact live provider discovery."

  alias Robine.ExecutionContext

  alias Robine.Repositories.UseCases.{
    DiscoverSourceControlRepositories,
    RegisterSourceControlRepository
  }

  @providers [:github, :gitlab, :forgejo]

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(input, %ExecutionContext{actor: %{role: :administrator}} = context) do
    with {:ok, selected} <- selection(input),
         {:ok, available} <- DiscoverSourceControlRepositories.call(selected, context),
         repository when not is_nil(repository) <- Enum.find(available, &matches?(&1, selected)) do
      RegisterSourceControlRepository.call(
        Map.take(repository, [
          :provider,
          :provider_instance,
          :provider_id,
          :installation_id,
          :full_name
        ]),
        context
      )
    else
      nil -> {:error, :repository_not_granted_to_source_control}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp selection(input) do
    provider = parse_provider(Map.get(input, :provider))
    provider_instance = Map.get(input, :provider_instance, "default")
    full_name = Map.get(input, :full_name)

    with provider when provider in @providers <- provider,
         true <- is_binary(provider_instance) and byte_size(provider_instance) in 1..64,
         {provider_id, ""} <- Integer.parse(to_string(Map.get(input, :provider_id))),
         {installation_id, ""} <-
           Integer.parse(to_string(Map.get(input, :installation_id, 0))),
         true <- is_binary(full_name) and full_name != "" do
      {:ok,
       %{
         provider: provider,
         provider_instance: provider_instance,
         provider_id: provider_id,
         installation_id: installation_id,
         full_name: full_name
       }}
    else
      _invalid -> {:error, :invalid_repository_selection}
    end
  end

  defp parse_provider(provider) when provider in @providers, do: provider
  defp parse_provider("github"), do: :github
  defp parse_provider("gitlab"), do: :gitlab
  defp parse_provider("forgejo"), do: :forgejo
  defp parse_provider(_provider), do: nil

  defp matches?(repository, selected),
    do:
      repository.provider == selected.provider and
        repository.provider_instance == selected.provider_instance and
        repository.provider_id == selected.provider_id and
        repository.installation_id == selected.installation_id and
        repository.full_name == selected.full_name
end
