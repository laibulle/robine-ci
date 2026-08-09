defmodule Robine.Adapters.SourceControl.GitHubClient do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.SourceControl

  @api "https://api.github.com"
  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Adapters.SourceControl.{GitHubAppTokenCache, GitHubTelemetry}

  @impl true
  def workflow_files(repository, sha) do
    with {:ok, token} <- token(repository),
         {:ok, response} <-
           request(:get, workflow_directory_url(repository), token, params: [ref: sha]),
         entries when is_list(entries) <- response.body do
      entries
      |> Enum.filter(&workflow_entry?/1)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, files} ->
        case request(:get, entry["url"], token, params: [ref: sha]) do
          {:ok, %{body: %{"content" => content, "encoding" => "base64"}}} ->
            case Base.decode64(String.replace(content, ~r/\s/, "")) do
              {:ok, decoded} ->
                {:cont, {:ok, files ++ [%{path: entry["path"], content: decoded}]}}

              :error ->
                {:halt, {:error, :invalid_github_content}}
            end

          {:ok, response} ->
            {:halt, {:error, {:unexpected_github_response, response.status}}}

          error ->
            {:halt, error}
        end
      end)
    else
      %{"message" => "Not Found"} -> {:ok, []}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_github_response, other}}
    end
  end

  @impl true
  def default_branch_head(repository) do
    with {:ok, token} <- token(repository),
         {:ok, %{body: %{"default_branch" => branch}}} when is_binary(branch) <-
           request(:get, "#{@api}/repos/#{repository.full_name}", token, []),
         {:ok, %{body: %{"sha" => sha}}} when is_binary(sha) <-
           request(
             :get,
             "#{@api}/repos/#{repository.full_name}/commits/#{URI.encode(branch)}",
             token,
             []
           ),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      {:ok, %{branch: branch, sha: sha}}
    else
      false -> {:error, :invalid_default_branch_head}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_default_branch_head}
    end
  end

  @impl true
  def upsert_check(repository, check) do
    provider_check_id = Map.get(check, :provider_check_id)
    payload = Map.drop(check, [:provider_check_id])

    {method, url, payload} =
      if provider_check_id do
        {:patch, "#{@api}/repos/#{repository.full_name}/check-runs/#{provider_check_id}",
         Map.delete(payload, :head_sha)}
      else
        {:post, "#{@api}/repos/#{repository.full_name}/check-runs", payload}
      end

    with {:ok, token} <- token(repository),
         {:ok, %{body: %{"id" => id}}} <- request(method, url, token, json: payload) do
      {:ok, id}
    end
  end

  @impl true
  def source_files(repository, sha) do
    with {:ok, token} <- token(repository),
         {:ok, %{body: body}} <-
           request(
             :get,
             "#{@api}/repos/#{repository.owner}/#{repository.name}/tarball/#{sha}",
             token,
             decode_body: false
           ),
         true <- is_binary(body),
         {:ok, files} <- SafeTar.extract_source(body) do
      {:ok, files}
    else
      false -> {:error, :invalid_source_archive}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_source_archive, other}}
    end
  end

  @impl true
  def installation_permissions(repository) do
    GitHubAppTokenCache.permissions(repository.installation_id)
  end

  @impl true
  def available_repositories do
    with {:ok, app_token} <- GitHubAppTokenCache.app_token(),
         {:ok, installations} <-
           paginated("#{@api}/app/installations", app_token, &installation_page/1) do
      installations
      |> Enum.reject(&(not is_nil(&1["suspended_at"])))
      |> Enum.reduce_while({:ok, []}, fn installation, {:ok, repositories} ->
        case installation_repositories(installation["id"]) do
          {:ok, values} -> {:cont, {:ok, repositories ++ values}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_github_installations_response}
    end
  end

  defp installation_repositories(installation_id) when is_integer(installation_id) do
    with {:ok, token} <- GitHubAppTokenCache.token(installation_id),
         {:ok, repositories} <-
           paginated("#{@api}/installation/repositories", token, &repository_page/1) do
      {:ok,
       Enum.map(repositories, fn repository ->
         %{
           provider_id: repository["id"],
           installation_id: installation_id,
           full_name: repository["full_name"],
           private: repository["private"] == true
         }
       end)}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_github_repositories_response}
    end
  end

  defp paginated(url, token, page_decoder, page \\ 1, accumulated \\ [])

  defp paginated(_url, _token, _page_decoder, page, _accumulated) when page > 100,
    do: {:error, :github_pagination_limit}

  defp paginated(url, token, page_decoder, page, accumulated) do
    with {:ok, %{body: body}} <-
           request(:get, url, token, params: [per_page: 100, page: page]),
         {:ok, values} <- page_decoder.(body) do
      combined = accumulated ++ values

      if length(values) == 100,
        do: paginated(url, token, page_decoder, page + 1, combined),
        else: {:ok, combined}
    end
  end

  defp installation_page(installations) when is_list(installations), do: {:ok, installations}
  defp installation_page(_body), do: {:error, :invalid_github_installations_response}

  defp repository_page(%{"repositories" => repositories}) when is_list(repositories),
    do: {:ok, repositories}

  defp repository_page(_body), do: {:error, :invalid_github_repositories_response}

  defp workflow_directory_url(repository),
    do: "#{@api}/repos/#{repository.owner}/#{repository.name}/contents/.robine-ci/workflows"

  defp workflow_entry?(%{"type" => "file", "name" => name}) do
    String.ends_with?(name, [".yml", ".yaml"])
  end

  defp workflow_entry?(_entry), do: false

  defp token(repository), do: GitHubAppTokenCache.token(repository.installation_id)

  defp request(method, url, token, options) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "Robine-CI"}
    ]

    options = Keyword.merge([method: method, url: url, headers: headers, retry: false], options)

    started = System.monotonic_time()
    result = Req.request(options)
    :ok = GitHubTelemetry.emit(method, started, result)

    case result do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: 404, body: %{"message" => "Not Found"}} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:github_http, response.status}}
      {:error, reason} -> {:error, {:github_transport, reason}}
    end
  end
end
