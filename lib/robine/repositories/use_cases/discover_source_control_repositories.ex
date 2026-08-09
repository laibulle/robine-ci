defmodule Robine.Repositories.UseCases.DiscoverSourceControlRepositories do
  @moduledoc "Lists repositories granted to one configured source-control provider."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies

  @providers [:github, :gitlab, :forgejo]

  @spec call(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = dependencies}
      }) do
    with {:ok, provider, provider_instance} <- selection(input),
         true <- function_exported?(dependencies.source_control, :available_repositories, 2),
         {:ok, repositories} <-
           dependencies.source_control.available_repositories(provider, provider_instance),
         true <- Enum.all?(repositories, &valid?/1) do
      {:ok,
       repositories
       |> Enum.map(&Map.merge(&1, %{provider: provider, provider_instance: provider_instance}))
       |> Enum.sort_by(&String.downcase(&1.full_name))}
    else
      false -> {:error, :source_control_discovery_unsupported}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp selection(input) do
    provider = Map.get(input, :provider)
    instance = Map.get(input, :provider_instance, "default")

    if provider in @providers and is_binary(instance) and byte_size(instance) in 1..64,
      do: {:ok, provider, instance},
      else: {:error, :invalid_source_control_provider}
  end

  defp valid?(repository) do
    is_integer(repository.provider_id) and repository.provider_id > 0 and
      is_integer(repository.installation_id) and repository.installation_id >= 0 and
      is_binary(repository.full_name) and repository.full_name != "" and
      is_boolean(repository.private)
  end
end
