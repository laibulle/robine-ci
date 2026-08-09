defmodule Robine.Adapters.SourceControl.ForgejoClient do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.SourceControl

  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Adapters.SourceControl.ProviderRequest

  @discovery_page_size 100
  @discovery_page_limit 100

  @impl true
  def workflow_files(repository, sha) do
    base = repository_path(repository)

    with :ok <- exact_sha(sha),
         {:ok, %{body: entries}} when is_list(entries) <-
           ProviderRequest.call(
             :forgejo,
             :get,
             "#{base}/contents/.robine-ci/workflows",
             params: [ref: sha]
           ) do
      entries
      |> Enum.filter(&workflow_entry?/1)
      |> Enum.take(100)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, files} ->
        encoded = encode_path(entry["path"])

        case ProviderRequest.call(:forgejo, :get, "#{base}/contents/#{encoded}",
               params: [ref: sha],
               max_body: 524_288
             ) do
          {:ok, %{body: %{"content" => content, "encoding" => "base64"}}}
          when is_binary(content) ->
            case Base.decode64(String.replace(content, ~r/\s/, "")) do
              {:ok, source} when byte_size(source) <= 262_144 ->
                {:cont, {:ok, files ++ [%{path: entry["path"], content: source}]}}

              _invalid ->
                {:halt, {:error, :invalid_forgejo_workflow_response}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}

          _invalid ->
            {:halt, {:error, :invalid_forgejo_workflow_response}}
        end
      end)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_forgejo_workflow_response}
    end
  end

  @impl true
  def default_branch_head(repository) do
    base = repository_path(repository)

    with {:ok, %{body: %{"default_branch" => branch}}} when is_binary(branch) <-
           ProviderRequest.call(:forgejo, :get, base),
         {:ok, %{body: commit}} when is_map(commit) <-
           ProviderRequest.call(
             :forgejo,
             :get,
             "#{base}/git/commits/#{URI.encode(branch)}"
           ),
         sha when is_binary(sha) <- commit["sha"] || commit["id"],
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
             :forgejo,
             :get,
             "#{repository_path(repository)}/archive/#{sha}.tar.gz",
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
      target_url: check.details_url,
      description: bounded(get_in(check, [:output, :summary]) || check.name, 255),
      context: bounded(check.name, 255)
    }

    with :ok <- exact_sha(check.head_sha),
         {:ok, %{body: body}} <-
           ProviderRequest.call(
             :forgejo,
             :post,
             "#{repository_path(repository)}/statuses/#{check.head_sha}",
             json: payload
           ),
         id when is_integer(id) <- body["id"] || stable_status_id(check.external_id) do
      {:ok, id}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_forgejo_status_response}
    end
  end

  @impl true
  def installation_permissions(repository) do
    case ProviderRequest.call(:forgejo, :get, repository_path(repository)) do
      {:ok, _response} -> {:ok, %{repository: "read", status: "write"}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def available_repositories do
    discover_page(1, [])
  end

  defp discover_page(page, repositories) when page <= @discovery_page_limit do
    case ProviderRequest.call(:forgejo, :get, "/api/v1/user/repos",
           params: [limit: @discovery_page_size, page: page]
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
        {:error, :invalid_forgejo_repository_discovery}
    end
  end

  defp discover_page(_page, _repositories),
    do: {:error, :source_control_repository_discovery_limit_exceeded}

  defp normalize_repositories(repositories) do
    values =
      Enum.flat_map(repositories, fn
        %{"id" => id, "full_name" => name} = repository
        when is_integer(id) and is_binary(name) ->
          [
            %{
              provider_id: id,
              installation_id: 0,
              full_name: name,
              private: repository["private"] == true
            }
          ]

        _invalid ->
          []
      end)

    if length(values) == length(repositories),
      do: {:ok, values},
      else: {:error, :invalid_forgejo_repository_discovery}
  end

  defp workflow_entry?(%{"type" => "file", "path" => path}) when is_binary(path),
    do: String.ends_with?(path, ".yml")

  defp workflow_entry?(_entry), do: false

  defp repository_path(repository),
    do: "/api/v1/repos/#{URI.encode(repository.owner)}/#{URI.encode(repository.name)}"

  defp encode_path(path),
    do: path |> String.split("/") |> Enum.map_join("/", &URI.encode/1)

  defp exact_sha(sha) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: :ok, else: {:error, :invalid_commit_sha}
  end

  defp exact_sha(_sha), do: {:error, :invalid_commit_sha}

  defp status(%{status: :queued}), do: "pending"
  defp status(%{status: :in_progress}), do: "pending"
  defp status(%{conclusion: :success}), do: "success"
  defp status(%{conclusion: :failure}), do: "failure"
  defp status(%{conclusion: :cancelled}), do: "error"
  defp status(%{conclusion: :neutral}), do: "warning"
  defp status(_check), do: "pending"

  defp bounded(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp stable_status_id(value), do: :erlang.phash2(value, 2_147_483_647) + 1
end
