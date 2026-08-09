defmodule Robine.Adapters.SourceControl.GitHubClient do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.GitHub

  @api "https://api.github.com"
  alias Robine.Adapters.Archive.SafeTar
  alias Robine.Adapters.SourceControl.GitHubAppTokenCache

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

    case Req.request(options) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: 404, body: %{"message" => "Not Found"}} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:github_http, response.status, response.body}}
      {:error, reason} -> {:error, {:github_transport, reason}}
    end
  end
end
