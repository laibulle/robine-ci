defmodule Robine.Repositories.GitHubDeliveryTest do
  use Robine.DataCase, async: false

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{GitHubDelivery, Pipeline}
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
    def upsert_check(_repository, _check), do: :ok
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
      "ref" => "refs/heads/main"
    }

    accept(delivery_id, "push", payload, context)

    assert {:ok, %{pipeline_ids: [pipeline_id], commit_sha: ^sha}} =
             Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    assert_receive {:workflow_files, "acme/widget", ^sha}

    repository_id = repository.id

    assert %Pipeline{id: ^pipeline_id, repository_id: ^repository_id, commit_sha: ^sha} =
             Repo.get!(Pipeline, pipeline_id)

    assert Repo.get!(GitHubDelivery, delivery_id).status == :processed
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
