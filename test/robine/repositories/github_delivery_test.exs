defmodule Robine.Repositories.GitHubDeliveryTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    GitHubCheck,
    GitHubDelivery,
    Pipeline
  }

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  defmodule FakeGitHub do
    @behaviour Robine.Repositories.Ports.GitHub

    @impl true
    def workflow_files(repository, sha) do
      send(self(), {:workflow_files, repository.full_name, sha})

      {:ok,
       [
         %{
           path: ".robine-ci/workflows/ci.yml",
           content: """
           version: 1
           name: CI
           on:
             push:
               branches: [main]
             pull_request: {}
           jobs:
             test:
               image: postgres:18-alpine
               steps:
                 - name: Test
                   run: "true"
           """
         }
       ]}
    end

    @impl true
    def source_files(_repository, _sha), do: {:ok, [{"README.md", "source"}]}

    @impl true
    def upsert_check(repository, check) do
      send(self(), {:upsert_check, repository.full_name, check})
      {:ok, :erlang.phash2(check.external_id)}
    end

    @impl true
    def installation_permissions(_repository),
      do: {:ok, %{"metadata" => "read", "contents" => "read", "checks" => "write"}}
  end

  test "processes a matching push from the exact commit only once" do
    context = context_with_fake_github()
    provider_id = 42_424_242
    repository = register(context, provider_id)
    sha = String.duplicate("a", 40)
    delivery_id = "push-delivery"

    payload = %{
      "repository" => %{"id" => provider_id},
      "after" => sha,
      "ref" => "refs/heads/main",
      "sender" => %{"login" => "octocat"}
    }

    accept(delivery_id, "push", payload, context)

    assert {:ok, %{pipeline_ids: [pipeline_id], commit_sha: ^sha}} =
             Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    assert_receive {:workflow_files, "acme/widget", ^sha}

    repository_id = repository.id

    assert %Pipeline{
             id: ^pipeline_id,
             repository_id: ^repository_id,
             commit_sha: ^sha,
             trigger: "push",
             actor: "github:octocat",
             correlation_id: "github-test"
           } =
             Repo.get!(Pipeline, pipeline_id)

    assert Repo.get!(GitHubDelivery, delivery_id).status == :processed

    assert {:ok, %{pipeline_ids: [^pipeline_id]}} =
             Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    assert Repo.aggregate(Pipeline, :count) == 1
  end

  test "processes reordered deliveries independently at each exact commit" do
    context = context_with_fake_github()
    provider_id = 44_444_444
    _repository = register(context, provider_id)
    older_sha = String.duplicate("1", 40)
    newer_sha = String.duplicate("2", 40)

    for {delivery_id, sha} <- [{"older-push", older_sha}, {"newer-push", newer_sha}] do
      accept(
        delivery_id,
        "push",
        %{
          "repository" => %{"id" => provider_id},
          "after" => sha,
          "ref" => "refs/heads/main"
        },
        context
      )
    end

    assert {:ok, %{commit_sha: ^newer_sha}} =
             Repositories.process_github_delivery(%{delivery_id: "newer-push"}, context)

    assert {:ok, %{commit_sha: ^older_sha}} =
             Repositories.process_github_delivery(%{delivery_id: "older-push"}, context)

    assert Repo.all(Pipeline)
           |> Enum.map(& &1.commit_sha)
           |> Enum.sort() == [older_sha, newer_sha]
  end

  test "checks installation permissions through the public facade" do
    context = context_with_fake_github()
    repository = register(context, 43_434_343)

    assert {:ok, %{status: :ok, missing: []}} =
             Repositories.check_github_installation(
               %{repository_id: repository.id},
               context
             )
  end

  test "ignores fork pull requests without fetching or creating a pipeline" do
    context = context_with_fake_github()
    provider_id = 52_525_252
    _repository = register(context, provider_id)
    delivery_id = "fork-delivery"

    payload = %{
      "action" => "synchronize",
      "repository" => %{"id" => provider_id},
      "pull_request" => %{
        "head" => %{
          "sha" => String.duplicate("b", 40),
          "repo" => %{"full_name" => "contributor/widget"}
        },
        "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/widget"}}
      }
    }

    accept(delivery_id, "pull_request", payload, context)

    assert {:ok, %{ignored: :fork_pull_request}} =
             Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    refute_received {:workflow_files, _, _}
    assert Repo.aggregate(Pipeline, :count) == 0
    assert Repo.get!(GitHubDelivery, delivery_id).status == :ignored
  end

  test "ignores draft pull requests until ready for review" do
    context = context_with_fake_github()
    provider_id = 72_727_272
    _repository = register(context, provider_id)

    payload = %{
      "action" => "opened",
      "repository" => %{"id" => provider_id},
      "pull_request" => %{
        "draft" => true,
        "head" => %{"sha" => String.duplicate("d", 40), "repo" => %{"full_name" => "acme/widget"}},
        "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/widget"}}
      }
    }

    accept("draft-delivery", "pull_request", payload, context)

    assert {:ok, %{ignored: :draft_pull_request}} =
             Repositories.process_github_delivery(%{delivery_id: "draft-delivery"}, context)

    refute_received {:workflow_files, _, _}
  end

  test "creates and then updates stable pipeline and job checks" do
    context = context_with_fake_github()
    provider_id = 62_626_262
    _repository = register(context, provider_id)
    sha = String.duplicate("c", 40)
    delivery_id = "checks-delivery"

    accept(
      delivery_id,
      "push",
      %{
        "repository" => %{"id" => provider_id},
        "after" => sha,
        "ref" => "refs/heads/main"
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert_receive {:upsert_check, "acme/widget", %{external_id: pipeline_external_id}}
    assert_receive {:upsert_check, "acme/widget", %{external_id: job_external_id}}
    assert pipeline_external_id == "pipeline:#{pipeline_id}"
    assert String.starts_with?(job_external_id, "job:")

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert_receive {:upsert_check, "acme/widget",
                    %{external_id: ^pipeline_external_id, provider_check_id: pipeline_check_id}}

    assert_receive {:upsert_check, "acme/widget",
                    %{external_id: ^job_external_id, provider_check_id: job_check_id}}

    assert is_integer(pipeline_check_id)
    assert is_integer(job_check_id)
    assert Repo.aggregate(GitHubCheck, :count) == 2
  end

  test "fetches validated source for a trusted repository at the exact SHA" do
    context = context_with_fake_github()
    repository = register(context, 82_828_282)
    sha = String.duplicate("8", 40)

    assert {:ok,
            %{repository_id: repository_id, commit_sha: ^sha, files: [{"README.md", "source"}]}} =
             Repositories.fetch_source(
               %{repository_id: repository.id, commit_sha: sha},
               context
             )

    assert repository_id == repository.id

    assert {:error, :untrusted_or_invalid_source} =
             Repositories.fetch_source(
               %{repository_id: repository.id, commit_sha: "main"},
               context
             )
  end

  defp context_with_fake_github do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "github-test")
    dependencies = context.dependencies.repositories
    fake = %{dependencies | github: FakeGitHub}
    %{context | dependencies: Map.put(context.dependencies, :repositories, fake)}
  end

  defp register(context, provider_id) do
    assert {:ok, view} =
             Repositories.register_github_repository(
               %{provider_id: provider_id, installation_id: 99, full_name: "acme/widget"},
               context
             )

    {:ok, repository} =
      context.dependencies.repositories.repository.get_by_provider_id(provider_id)

    assert view.id == repository.id
    repository
  end

  defp accept(id, event, payload, context) do
    body = Jason.encode!(payload)
    secret = Application.fetch_env!(:robine, :github_webhook_secret)

    signature =
      "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))

    assert {:ok, :accepted} =
             Repositories.accept_github_webhook(
               %{delivery_id: id, event: event, signature: signature, body: body},
               context
             )
  end
end
