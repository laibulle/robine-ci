defmodule Robine.Adapters.SourceControl.ProviderClientsTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.SourceControl.{
    ForgejoClient,
    GitLabClient,
    ProviderCredentials,
    ProviderRegistry
  }

  alias Robine.Repositories.Domain.Repository
  alias Robine.{Secrets}
  alias Robine.Runtime.Dependencies

  defmodule FakeHttpClient do
    @behaviour Robine.Adapters.SourceControl.HttpClient

    @impl true
    def request(options) do
      send(self(), {:provider_request, options})

      case Process.get({__MODULE__, :responses}, []) do
        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          response

        [] ->
          {:error, :unexpected_request}
      end
    end
  end

  setup do
    previous = %{
      gitlab: Application.get_env(:robine, :gitlab_source_control),
      forgejo: Application.get_env(:robine, :forgejo_source_control),
      gitlab_token: Application.get_env(:robine, :gitlab_token),
      forgejo_token: Application.get_env(:robine, :forgejo_token)
    }

    Application.put_env(:robine, :gitlab_source_control,
      base_url: "https://gitlab.example.test",
      http_client: FakeHttpClient
    )

    Application.put_env(:robine, :forgejo_source_control,
      base_url: "https://forgejo.example.test",
      http_client: FakeHttpClient
    )

    Application.put_env(:robine, :gitlab_token, "gitlab-test-token")
    Application.put_env(:robine, :forgejo_token, "forgejo-test-token")

    on_exit(fn ->
      restore(:gitlab_source_control, previous.gitlab)
      restore(:forgejo_source_control, previous.forgejo)
      restore(:gitlab_token, previous.gitlab_token)
      restore(:forgejo_token, previous.forgejo_token)
    end)

    :ok
  end

  test "provider registry loads a configured adapter before capability detection" do
    previous = Application.fetch_env!(:robine, :github_adapter)
    adapter = Robine.Test.UnloadedSourceControlAdapter
    Application.put_env(:robine, :github_adapter, adapter)

    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous) end)

    :code.purge(adapter)
    :code.delete(adapter)
    refute Code.loaded?(adapter)

    assert {:ok, [%{full_name: "acme/widget"}]} = ProviderRegistry.available_repositories()
    assert Code.loaded?(adapter)
  end

  test "GitLab reads workflow files and the default head only at the requested exact SHA" do
    sha = String.duplicate("a", 40)

    responses([
      {:ok,
       %{
         status: 200,
         body: [
           %{
             "type" => "blob",
             "path" => ".robine-ci/workflows/ci.yml",
             "name" => "ci.yml"
           }
         ]
       }},
      {:ok, %{status: 200, body: "version: 1\nname: CI\n"}},
      {:ok, %{status: 200, body: %{"default_branch" => "main"}}},
      {:ok, %{status: 200, body: %{"id" => sha}}}
    ])

    assert {:ok, [%{path: ".robine-ci/workflows/ci.yml", content: source}]} =
             GitLabClient.workflow_files(repository(:gitlab), sha)

    assert source =~ "name: CI"
    assert_request("/api/v4/projects/77/repository/tree", private_token: "gitlab-test-token")

    assert_request(
      "/api/v4/projects/77/repository/files/.robine-ci%2Fworkflows%2Fci.yml/raw",
      ref: sha
    )

    assert {:ok, %{branch: "main", sha: ^sha}} =
             GitLabClient.default_branch_head(repository(:gitlab))

    assert_request("/api/v4/projects/77")
    assert_request("/api/v4/projects/77/repository/commits/main")
  end

  test "Forgejo decodes exact-revision workflow content and translates commit status" do
    sha = String.duplicate("b", 40)
    source = "version: 1\nname: Forgejo CI\n"

    responses([
      {:ok,
       %{
         status: 200,
         body: [%{"type" => "file", "path" => ".robine-ci/workflows/ci.yml"}]
       }},
      {:ok, %{status: 200, body: %{"encoding" => "base64", "content" => Base.encode64(source)}}},
      {:ok, %{status: 201, body: %{"id" => 912}}}
    ])

    assert {:ok, [%{content: ^source}]} =
             ForgejoClient.workflow_files(repository(:forgejo), sha)

    assert_request("/api/v1/repos/acme/widget/contents/.robine-ci/workflows",
      authorization: "token forgejo-test-token"
    )

    assert_request("/api/v1/repos/acme/widget/contents/.robine-ci/workflows/ci.yml",
      ref: sha
    )

    assert {:ok, 912} = ForgejoClient.upsert_check(repository(:forgejo), check(sha, :success))

    assert_receive {:provider_request, options}
    assert URI.parse(options[:url]).path == "/api/v1/repos/acme/widget/statuses/#{sha}"
    assert options[:json].state == "success"
    assert options[:json].target_url == "https://ci.example.test/pipelines/1"
  end

  test "both providers reject mutable SHAs, redirects, and oversized responses" do
    assert {:error, :invalid_commit_sha} =
             GitLabClient.workflow_files(repository(:gitlab), "main")

    refute_received {:provider_request, _options}

    responses([{:ok, %{status: 302, body: "redirect"}}])

    assert {:error, {:gitlab, :cross_origin_or_redirect, 302}} =
             GitLabClient.available_repositories()

    responses([{:ok, %{status: 200, body: String.duplicate("x", 2_097_153)}}])

    assert {:error, :source_control_response_too_large} =
             ForgejoClient.available_repositories()
  end

  test "encrypted instance credentials override environment bootstrap tokens" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "provider-credential")

    assert {:ok, _metadata} =
             Secrets.store_secret(
               %{
                 name: "GITLAB_TOKEN",
                 value: "encrypted-gitlab-token",
                 scope: :instance,
                 allowed_repository_ids: []
               },
               context
             )

    assert {:ok, "encrypted-gitlab-token"} = ProviderCredentials.fetch(:gitlab, :token)
  end

  test "both providers extract bounded source archives fetched by exact commit" do
    sha = String.duplicate("c", 40)

    assert {:ok, archive} =
             Robine.Adapters.Archive.SafeTar.create_source(%{"README.md" => "exact source"})

    responses([{:ok, %{status: 200, body: archive}}])

    assert {:ok, [%{path: "README.md", content: "exact source", mode: 0o644}]} =
             GitLabClient.source_files(repository(:gitlab), sha)

    assert_receive {:provider_request, gitlab_request}
    assert URI.parse(gitlab_request[:url]).path == "/api/v4/projects/77/repository/archive.tar.gz"
    assert gitlab_request[:params][:sha] == sha
    assert gitlab_request[:decode_body] == false

    responses([{:ok, %{status: 200, body: archive}}])

    assert {:ok, [%{path: "README.md", content: "exact source", mode: 0o644}]} =
             ForgejoClient.source_files(repository(:forgejo), sha)

    assert_receive {:provider_request, forgejo_request}

    assert URI.parse(forgejo_request[:url]).path ==
             "/api/v1/repos/acme/widget/archive/#{sha}.tar.gz"

    assert forgejo_request[:decode_body] == false
  end

  test "repository discovery follows bounded provider pagination" do
    gitlab_page =
      for id <- 1..100 do
        %{"id" => id, "path_with_namespace" => "acme/project-#{id}", "visibility" => "private"}
      end

    responses([
      {:ok, %{status: 200, body: gitlab_page}},
      {:ok,
       %{
         status: 200,
         body: [%{"id" => 101, "path_with_namespace" => "acme/project-101"}]
       }}
    ])

    assert {:ok, gitlab_repositories} = GitLabClient.available_repositories()
    assert length(gitlab_repositories) == 101
    assert_request("/api/v4/projects", page: 1)
    assert_request("/api/v4/projects", page: 2)

    forgejo_page =
      for id <- 1..100 do
        %{"id" => id, "full_name" => "acme/project-#{id}", "private" => true}
      end

    responses([
      {:ok, %{status: 200, body: forgejo_page}},
      {:ok, %{status: 200, body: [%{"id" => 101, "full_name" => "acme/project-101"}]}}
    ])

    assert {:ok, forgejo_repositories} = ForgejoClient.available_repositories()
    assert length(forgejo_repositories) == 101
    assert_request("/api/v1/user/repos", page: 1)
    assert_request("/api/v1/user/repos", page: 2)
  end

  defp responses(values), do: Process.put({FakeHttpClient, :responses}, values)

  defp assert_request(path, expectations \\ []) do
    assert_receive {:provider_request, options}
    assert URI.parse(options[:url]).path == path

    if token = expectations[:private_token] do
      assert {"private-token", token} in options[:headers]
    end

    if token = expectations[:authorization] do
      assert {"authorization", token} in options[:headers]
    end

    if ref = expectations[:ref], do: assert(options[:params][:ref] == ref)
    if page = expectations[:page], do: assert(options[:params][:page] == page)
  end

  defp repository(provider) do
    %Repository{
      id: Ecto.UUID.generate(),
      provider: provider,
      provider_instance: "default",
      provider_id: 77,
      installation_id: 0,
      owner: "acme",
      name: "widget",
      full_name: "acme/widget",
      trusted: true,
      inserted_at: DateTime.utc_now()
    }
  end

  defp check(sha, conclusion) do
    %{
      name: "Robine / test",
      head_sha: sha,
      status: :completed,
      conclusion: conclusion,
      details_url: "https://ci.example.test/pipelines/1",
      external_id: "pipeline:1",
      output: %{summary: "Pipeline is succeeded."}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:robine, key)
  defp restore(key, value), do: Application.put_env(:robine, key, value)
end
