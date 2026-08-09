defmodule Robine.Adapters.SourceControl.ProviderRegistry do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.SourceControl

  @impl true
  def workflow_files(repository, sha), do: invoke(repository, :workflow_files, [repository, sha])

  @impl true
  def default_branch_head(repository),
    do: invoke(repository, :default_branch_head, [repository])

  @impl true
  def branch_head(repository, branch),
    do: invoke(repository, :branch_head, [repository, branch])

  @impl true
  def source_files(repository, sha), do: invoke(repository, :source_files, [repository, sha])

  @impl true
  def upsert_check(repository, check), do: invoke(repository, :upsert_check, [repository, check])

  @impl true
  def installation_permissions(repository),
    do: invoke(repository, :installation_permissions, [repository])

  @impl true
  def publish_release(repository, release),
    do: invoke(repository, :publish_release, [repository, release])

  @impl true
  def available_repositories, do: available_repositories(:github, "default")

  @impl true
  def available_repositories(provider, provider_instance)
      when provider in [:github, :gitlab, :forgejo] and is_binary(provider_instance) do
    with {:ok, adapter} <- adapter(provider, provider_instance),
         true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :available_repositories, 0) do
      adapter.available_repositories()
    else
      false -> {:error, :source_control_discovery_unsupported}
      {:error, _reason} = error -> error
    end
  end

  def available_repositories(_provider, _instance),
    do: {:error, :unknown_source_control_provider}

  @spec adapter(:github | :gitlab | :forgejo, String.t()) :: {:ok, module()} | {:error, term()}
  def adapter(:github, "default") do
    adapter = Application.fetch_env!(:robine, :github_adapter)

    if adapter == __MODULE__,
      do: {:error, :recursive_source_control_adapter},
      else: {:ok, adapter}
  end

  def adapter(:gitlab, "default"),
    do: configured(:gitlab_source_control, Robine.Adapters.SourceControl.GitLabClient)

  def adapter(:forgejo, "default"),
    do: configured(:forgejo_source_control, Robine.Adapters.SourceControl.ForgejoClient)

  def adapter(_provider, _instance), do: {:error, :unknown_source_control_provider}

  defp invoke(repository, function, arguments) do
    with {:ok, adapter} <- adapter(repository.provider, repository.provider_instance) do
      apply(adapter, function, arguments)
    end
  end

  defp configured(key, adapter) do
    case Application.get_env(:robine, key, []) |> Keyword.get(:base_url) do
      base_url when is_binary(base_url) and base_url != "" -> {:ok, adapter}
      _disabled -> {:error, :source_control_provider_disabled}
    end
  end
end
