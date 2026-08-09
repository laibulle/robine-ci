defmodule Robine.Adapters.SourceControl.GitLabClient do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.SourceControl

  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Adapters.SourceControl.ProviderRequest

  @discovery_page_size 100
  @discovery_page_limit 100

  @impl true
  def workflow_files(repository, sha) do
    project = project(repository)

    with :ok <- exact_sha(sha),
         {:ok, %{body: entries}} when is_list(entries) <-
           ProviderRequest.call(:gitlab, :get, "/api/v4/projects/#{project}/repository/tree",
             params: [path: ".robine-ci/workflows", ref: sha, per_page: 100]
           ) do
      entries
      |> Enum.filter(&workflow_entry?/1)
      |> Enum.take(100)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, files} ->
        encoded_path = URI.encode(entry["path"], &URI.char_unreserved?/1)

        case ProviderRequest.call(
               :gitlab,
               :get,
               "/api/v4/projects/#{project}/repository/files/#{encoded_path}/raw",
               params: [ref: sha],
               decode_body: false,
               max_body: 262_144
             ) do
          {:ok, %{body: source}} when is_binary(source) ->
            {:cont, {:ok, files ++ [%{path: entry["path"], content: source}]}}

          {:error, reason} ->
            {:halt, {:error, reason}}

          _invalid ->
            {:halt, {:error, :invalid_gitlab_workflow_response}}
        end
      end)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_gitlab_workflow_response}
    end
  end

  @impl true
  def default_branch_head(repository) do
    project = project(repository)

    with {:ok, %{body: %{"default_branch" => branch}}} when is_binary(branch) <-
           ProviderRequest.call(:gitlab, :get, "/api/v4/projects/#{project}"),
         {:ok, %{body: %{"id" => sha}}} when is_binary(sha) <-
           ProviderRequest.call(
             :gitlab,
             :get,
             "/api/v4/projects/#{project}/repository/commits/#{URI.encode(branch)}"
           ),
         :ok <- exact_sha(sha) do
      {:ok, %{branch: branch, sha: sha}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_default_branch_head}
    end
  end

  @impl true
  def source_files(repository, sha) do
    with :ok <- exact_sha(sha),
         {:ok, %{body: body}} when is_binary(body) <-
           ProviderRequest.call(
             :gitlab,
             :get,
             "/api/v4/projects/#{project(repository)}/repository/archive.tar.gz",
             params: [sha: sha],
             decode_body: false,
             max_body: ProviderRequest.archive_max_body()
           ),
         {:ok, files} <- SafeTar.extract_source(body) do
      {:ok, files}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_source_archive}
    end
  end

  @impl true
  def upsert_check(repository, check) do
    payload = %{
      state: status(check),
      name: bounded(check.name, 255),
      target_url: check.details_url,
      description: bounded(get_in(check, [:output, :summary]) || check.name, 255)
    }

    with :ok <- exact_sha(check.head_sha),
         {:ok, %{body: body}} <-
           ProviderRequest.call(
             :gitlab,
             :post,
             "/api/v4/projects/#{project(repository)}/statuses/#{check.head_sha}",
             json: payload
           ),
         id when is_integer(id) <- body["id"] || stable_status_id(check.external_id) do
      {:ok, id}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_gitlab_status_response}
    end
  end

  @impl true
  def installation_permissions(repository) do
    case ProviderRequest.call(:gitlab, :get, "/api/v4/projects/#{project(repository)}") do
      {:ok, %{body: %{"permissions" => permissions}}} when is_map(permissions) ->
        {:ok, permissions}

      {:ok, _response} ->
        {:ok, %{}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def available_repositories do
    discover_page(1, [])
  end

  defp discover_page(page, repositories) when page <= @discovery_page_limit do
    case ProviderRequest.call(:gitlab, :get, "/api/v4/projects",
           params: [
             membership: true,
             simple: true,
             per_page: @discovery_page_size,
             order_by: "id",
             sort: "asc",
             page: page
           ]
         ) do
      {:ok, %{body: values}} when is_list(values) ->
        with {:ok, normalized} <- normalize_repositories(values) do
          discovered = repositories ++ normalized

          if length(values) < @discovery_page_size do
            {:ok, discovered}
          else
            discover_page(page + 1, discovered)
          end
        end

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, :invalid_gitlab_repository_discovery}
    end
  end

  defp discover_page(_page, _repositories),
    do: {:error, :source_control_repository_discovery_limit_exceeded}

  defp normalize_repositories(repositories) do
    values =
      Enum.flat_map(repositories, fn
        %{"id" => id, "path_with_namespace" => name} = repository
        when is_integer(id) and is_binary(name) ->
          [
            %{
              provider_id: id,
              installation_id: 0,
              full_name: name,
              private: repository["visibility"] != "public"
            }
          ]

        _invalid ->
          []
      end)

    if length(values) == length(repositories),
      do: {:ok, values},
      else: {:error, :invalid_gitlab_repository_discovery}
  end

  defp workflow_entry?(%{"type" => "blob", "path" => path}) when is_binary(path),
    do: String.ends_with?(path, ".yml")

  defp workflow_entry?(_entry), do: false

  defp project(repository),
    do: URI.encode(Integer.to_string(repository.provider_id), &URI.char_unreserved?/1)

  defp exact_sha(sha) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: :ok, else: {:error, :invalid_commit_sha}
  end

  defp exact_sha(_sha), do: {:error, :invalid_commit_sha}

  defp status(%{status: :queued}), do: "pending"
  defp status(%{status: :in_progress}), do: "running"
  defp status(%{conclusion: :success}), do: "success"
  defp status(%{conclusion: :failure}), do: "failed"
  defp status(%{conclusion: :cancelled}), do: "canceled"
  defp status(%{conclusion: :neutral}), do: "skipped"
  defp status(_check), do: "pending"

  defp bounded(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp stable_status_id(value), do: :erlang.phash2(value, 2_147_483_647) + 1
end
