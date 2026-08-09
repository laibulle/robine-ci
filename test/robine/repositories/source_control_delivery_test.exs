defmodule Robine.Repositories.SourceControlDeliveryTest do
  use Robine.DataCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.{GitHubDelivery, Job, Pipeline}
  alias Robine.{Pipelines, Repositories, Runners}
  alias Robine.Runtime.Dependencies

  defmodule FakeWebhookVerifier do
    @behaviour Robine.Repositories.Ports.WebhookVerifier

    @impl true
    def verify(provider, _body, "valid") when provider in [:gitlab, :forgejo], do: :ok
    def verify(_provider, _body, _authentication), do: {:error, :invalid_signature}
  end

  defmodule FakeSourceControl do
    @behaviour Robine.Repositories.Ports.SourceControl

    @impl true
    def workflow_files(repository, sha) do
      send(self(), {:exact_workflow_fetch, repository.provider, repository.provider_id, sha})

      files =
        case Process.get({__MODULE__, :mode}) do
          :reusable -> reusable_files()
          _default -> ordinary_files()
        end

      {:ok, files}
    end

    defp ordinary_files do
      [
        %{
          path: ".robine-ci/workflows/ci.yml",
          content: """
          version: 1
          name: Multi-provider CI
          on:
            push: {branches: [main]}
            pull_request: {branches: [main]}
            workflow_dispatch:
              inputs:
                environment:
                  type: choice
                  required: true
                  options: [staging, production]
            schedule:
              - cron: "* * * * *"
          jobs:
            test:
              image: alpine:3.22
              steps: [{run: "true"}]
          """
        }
      ]
    end

    defp reusable_files do
      [
        %{
          path: ".robine-ci/workflows/ci.yml",
          content: """
          version: 1
          name: Reusable provider CI
          on: {push: {branches: [main]}}
          includes:
            quality:
              path: .robine-ci/workflows/quality.yml
              inputs: {runtime: "3.22"}
          jobs: {}
          """
        },
        %{
          path: ".robine-ci/workflows/quality.yml",
          content: """
          version: 1
          name: Shared quality
          on:
            workflow_call:
              inputs:
                runtime: {type: choice, required: true, options: ["3.21", "3.22"]}
          jobs:
            test:
              image: alpine:3.22
              steps: [{run: "true"}]
          """
        }
      ]
    end

    @impl true
    def upsert_check(repository, check) do
      if Process.get({__MODULE__, :status_mode}) == :error do
        {:error, :provider_unavailable}
      else
        send(self(), {:provider_status, repository.provider, check})
        {:ok, :erlang.phash2({repository.provider, check.external_id}) + 1}
      end
    end

    @impl true
    def default_branch_head(repository) do
      {:ok, %{branch: "main", sha: String.duplicate(provider_digit(repository.provider), 40)}}
    end

    @impl true
    def source_files(_repository, _sha), do: {:error, :not_used}
    @impl true
    def installation_permissions(_repository), do: {:ok, %{}}
    @impl true
    def available_repositories, do: {:ok, []}

    @impl true
    def available_repositories(provider, "default") when provider in [:gitlab, :forgejo] do
      {:ok,
       [
         %{
           provider_id: 701,
           installation_id: 0,
           full_name: "acme/discovered",
           private: true
         }
       ]}
    end

    defp provider_digit(:gitlab), do: "d"
    defp provider_digit(:forgejo), do: "e"
    defp provider_digit(:github), do: "f"
  end

  test "provider discovery re-verifies an exact selection before trust" do
    context = context()

    assert {:ok, [candidate]} =
             Repositories.discover_source_control_repositories(%{provider: :gitlab}, context)

    assert candidate.provider == :gitlab
    assert candidate.provider_instance == "default"

    assert {:error, :repository_not_granted_to_source_control} =
             Repositories.trust_source_control_repository(
               %{
                 provider: "gitlab",
                 provider_id: 999,
                 installation_id: 0,
                 full_name: "acme/discovered"
               },
               context
             )

    assert {:ok, trusted} =
             Repositories.trust_source_control_repository(
               %{
                 provider: "gitlab",
                 provider_id: 701,
                 installation_id: 0,
                 full_name: "acme/discovered"
               },
               context
             )

    assert trusted.provider == :gitlab
    assert trusted.full_name == "acme/discovered"

    assert {:ok, %{status: :ok, provider: :gitlab}} =
             Repositories.check_source_control_connection(
               %{repository_id: trusted.id},
               context
             )
  end

  test "equal external delivery IDs are deduplicated within, not across, providers" do
    context = context()
    external_id = "provider-shared-delivery"

    for provider <- [:gitlab, :forgejo] do
      assert {:ok, :accepted} =
               Repositories.accept_source_control_webhook(
                 %{
                   provider: provider,
                   delivery_id: external_id,
                   event: "ping",
                   authentication: "valid",
                   body: "{}"
                 },
                 context
               )

      assert {:ok, :duplicate} =
               Repositories.accept_source_control_webhook(
                 %{
                   provider: provider,
                   delivery_id: external_id,
                   event: "ping",
                   authentication: "valid",
                   body: "{}"
                 },
                 context
               )
    end

    assert Repo.aggregate(GitHubDelivery, :count) == 2

    assert Repo.all(from delivery in GitHubDelivery, select: delivery.id)
           |> Enum.uniq()
           |> length() ==
             2
  end

  test "GitLab and Forgejo push and change-request events create exact-SHA pipelines and statuses" do
    context = context()

    cases = [
      {:gitlab, "Push Hook", gitlab_push(81, String.duplicate("1", 40)), :push},
      {:gitlab, "Merge Request Hook", gitlab_merge(82, String.duplicate("2", 40)), :pull_request},
      {:forgejo, "push", forgejo_push(83, String.duplicate("3", 40)), :push},
      {:forgejo, "pull_request", forgejo_pull(84, String.duplicate("4", 40)), :pull_request}
    ]

    for {provider, event, payload, expected_trigger} <- cases do
      provider_id = provider_id(payload, provider)
      sha = event_sha(payload, provider, expected_trigger)

      assert {:ok, repository} =
               Repositories.register_source_control_repository(
                 %{
                   provider: provider,
                   provider_id: provider_id,
                   full_name: "acme/#{provider}-#{provider_id}"
                 },
                 context
               )

      external_delivery_id = "#{provider}-#{provider_id}-delivery"
      body = Jason.encode!(payload)

      assert {:ok, :accepted} =
               Repositories.accept_source_control_webhook(
                 %{
                   provider: provider,
                   delivery_id: external_delivery_id,
                   event: event,
                   authentication: "valid",
                   body: body
                 },
                 context
               )

      delivery =
        Repo.one!(
          from stored in GitHubDelivery,
            where:
              stored.provider == ^provider and
                stored.provider_delivery_id == ^external_delivery_id
        )

      assert {:ok, %{pipeline_ids: [pipeline_id], commit_sha: ^sha}} =
               Repositories.process_github_delivery(%{delivery_id: delivery.id}, context)

      assert_receive {:exact_workflow_fetch, ^provider, ^provider_id, ^sha}

      pipeline = Repo.get!(Pipeline, pipeline_id)
      assert pipeline.repository_id == repository.id
      assert pipeline.commit_sha == sha
      assert pipeline.trigger == to_string(expected_trigger)
      assert pipeline.actor =~ "#{provider}:"

      job = Repo.one!(from stored in Job, where: stored.pipeline_id == ^pipeline_id)
      assert job.job_key == "test"

      assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

      assert_receive {:provider_status, ^provider,
                      %{head_sha: ^sha, external_id: "pipeline:" <> _}}

      assert_receive {:provider_status, ^provider, %{head_sha: ^sha, external_id: "job:" <> _}}
    end

    assert Repo.aggregate(Pipeline, :count) == 4
  end

  test "drafts, forks, invalid authentication, and mutable commit IDs create no pipeline" do
    context = context()

    assert {:error, :invalid_signature} =
             Repositories.accept_source_control_webhook(
               %{
                 provider: :gitlab,
                 delivery_id: "invalid-auth",
                 event: "Push Hook",
                 authentication: "invalid",
                 body: Jason.encode!(gitlab_push(91, String.duplicate("a", 40)))
               },
               context
             )

    refute Repo.exists?(
             from stored in GitHubDelivery, where: stored.provider_delivery_id == "invalid-auth"
           )

    scenarios = [
      {:gitlab, "Merge Request Hook",
       put_in(gitlab_merge(92, String.duplicate("b", 40)), ["object_attributes", "draft"], true)},
      {:forgejo, "pull_request",
       put_in(
         forgejo_pull(93, String.duplicate("c", 40)),
         ["pull_request", "head", "repo", "full_name"],
         "fork/widget"
       )},
      {:gitlab, "Push Hook", gitlab_push(94, "main")}
    ]

    for {provider, event, payload} <- scenarios do
      provider_id = provider_id(payload, provider)

      assert {:ok, _repository} =
               Repositories.register_source_control_repository(
                 %{
                   provider: provider,
                   provider_id: provider_id,
                   full_name: "acme/repo-#{provider_id}"
                 },
                 context
               )

      delivery_id = "ignored-#{provider_id}"

      assert {:ok, :accepted} =
               Repositories.accept_source_control_webhook(
                 %{
                   provider: provider,
                   delivery_id: delivery_id,
                   event: event,
                   authentication: "valid",
                   body: Jason.encode!(payload)
                 },
                 context
               )

      stored =
        Repo.one!(from value in GitHubDelivery, where: value.provider_delivery_id == ^delivery_id)

      result = Repositories.process_github_delivery(%{delivery_id: stored.id}, context)

      assert match?({:ok, %{ignored: _reason}}, result) or
               match?({:error, {:invalid_webhook, :commit}}, result)
    end

    assert Repo.aggregate(Pipeline, :count) == 0
  end

  test "GitLab manual inputs launch the same exact-head execution contract" do
    context = context()

    assert {:ok, repository} =
             Repositories.register_source_control_repository(
               %{provider: :gitlab, provider_id: 201, full_name: "acme/manual"},
               context
             )

    sha = String.duplicate("d", 40)

    assert {:ok, %{commit_sha: ^sha, workflows: [workflow]}} =
             Repositories.list_manual_workflows(%{repository_id: repository.id}, context)

    assert {:ok, %{pipeline: pipeline, commit_sha: ^sha}} =
             Repositories.launch_manual_workflow(
               %{
                 repository_id: repository.id,
                 workflow_path: workflow.path,
                 request_id: "gitlab-manual",
                 inputs: %{"environment" => "production"}
               },
               context
             )

    stored = Repo.get!(Pipeline, pipeline.id)
    assert stored.trigger == "workflow_dispatch"
    assert stored.commit_sha == sha
    assert stored.inputs == %{"environment" => "production"}

    job = Repo.one!(from value in Job, where: value.pipeline_id == ^pipeline.id)
    assert job.execution_spec["env"]["ROBINE_INPUT_ENVIRONMENT"] == "production"
  end

  test "Forgejo scheduled reconciliation resolves one exact default head" do
    context = context()

    assert {:ok, repository} =
             Repositories.register_source_control_repository(
               %{provider: :forgejo, provider_id: 202, full_name: "acme/scheduled"},
               context
             )

    sha = String.duplicate("e", 40)

    assert {:ok, %{due_occurrences: 1, pipelines: 1}} =
             Repositories.reconcile_scheduled_workflows(%{}, context)

    pipeline = Repo.one!(from value in Pipeline, where: value.repository_id == ^repository.id)
    assert pipeline.trigger == "schedule"
    assert pipeline.commit_sha == sha
    assert pipeline.scheduled_for.second == 0
    assert pipeline.scheduled_for.microsecond == {0, 6}
  end

  test "a GitLab push composes and persists the same reusable exact-revision graph" do
    context = context()
    Process.put({FakeSourceControl, :mode}, :reusable)
    on_exit(fn -> Process.delete({FakeSourceControl, :mode}) end)
    sha = String.duplicate("9", 40)

    assert {:ok, repository} =
             Repositories.register_source_control_repository(
               %{provider: :gitlab, provider_id: 203, full_name: "acme/reusable"},
               context
             )

    payload = gitlab_push(203, sha)

    assert {:ok, :accepted} =
             Repositories.accept_source_control_webhook(
               %{
                 provider: :gitlab,
                 delivery_id: "gitlab-reusable",
                 event: "Push Hook",
                 authentication: "valid",
                 body: Jason.encode!(payload)
               },
               context
             )

    delivery =
      Repo.one!(
        from value in GitHubDelivery,
          where: value.provider_delivery_id == "gitlab-reusable"
      )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(%{delivery_id: delivery.id}, context)

    job = Repo.one!(from value in Job, where: value.pipeline_id == ^pipeline_id)
    assert job.job_key == "quality--test"
    assert job.execution_spec["env"]["ROBINE_CALL_INPUT_RUNTIME"] == "3.22"

    assert {:ok, revision} =
             Robine.Pipelines.workflow_revision(%{pipeline_id: pipeline_id}, context)

    assert revision.included_sources[".robine-ci/workflows/quality.yml"]["source"] =~
             "workflow_call"

    assert Repo.get!(Pipeline, pipeline_id).repository_id == repository.id

    anonymous_runner = Dependencies.context(%{id: "anonymous", role: :runner}, "gitlab-remote")
    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "gitlab-runner"}, anonymous_runner)

    runner_context =
      Dependencies.context(%{id: identity.runner_id, role: :runner}, "gitlab-remote")

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{"docker" => true, "concurrency" => 1}
               },
               runner_context
             )

    outbox = Repo.one!(from queued in Oban.Job, where: queued.queue == "outbox")
    assert :ok = perform_job(OutboxDeliveryWorker, outbox.args)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{runner_id: identity.runner_id}, context)

    assert {:ok, remote} =
             Pipelines.remote_job_execution(%{attempt_id: attempt.id}, runner_context)

    assert remote["commit_sha"] == sha
    assert remote["env"]["ROBINE_CALL_INPUT_RUNTIME"] == "3.22"
  end

  test "provider status outage preserves local truth and reconciles after recovery" do
    context = context()
    Process.put({FakeSourceControl, :status_mode}, :error)
    on_exit(fn -> Process.delete({FakeSourceControl, :status_mode}) end)

    assert {:ok, repository} =
             Repositories.register_source_control_repository(
               %{provider: :forgejo, provider_id: 204, full_name: "acme/outage"},
               context
             )

    assert {:ok, pipeline} =
             Robine.Pipelines.create_pipeline(
               %{
                 repository_id: repository.id,
                 workflow_name: "Outage",
                 commit_sha: String.duplicate("8", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    assert {:error, :provider_unavailable} =
             Repositories.sync_github_checks(%{pipeline_id: pipeline.id}, context)

    assert Repo.get!(Pipeline, pipeline.id).status == :created
    Process.delete({FakeSourceControl, :status_mode})

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline.id}, context)
    assert_receive {:provider_status, :forgejo, %{external_id: "pipeline:" <> _}}
    assert_receive {:provider_status, :forgejo, %{external_id: "job:" <> _}}
  end

  defp context do
    base = Dependencies.context(%{id: "admin", role: :administrator}, "source-control-test")
    repositories = base.dependencies.repositories

    configured = %{
      repositories
      | webhook_verifier: FakeWebhookVerifier,
        source_control: FakeSourceControl
    }

    put_in(base.dependencies.repositories, configured)
  end

  defp gitlab_push(id, sha) do
    %{
      "project" => %{"id" => id},
      "after" => sha,
      "ref" => "refs/heads/main",
      "user_username" => "gitlab-user"
    }
  end

  defp gitlab_merge(id, sha) do
    %{
      "project" => %{"id" => id},
      "user" => %{"username" => "gitlab-reviewer"},
      "object_attributes" => %{
        "action" => "update",
        "draft" => false,
        "title" => "Feature",
        "source_project_id" => id,
        "target_project_id" => id,
        "target_branch" => "main",
        "last_commit" => %{"id" => sha}
      }
    }
  end

  defp forgejo_push(id, sha) do
    %{
      "repository" => %{"id" => id},
      "after" => sha,
      "ref" => "refs/heads/main",
      "sender" => %{"login" => "forgejo-user"}
    }
  end

  defp forgejo_pull(id, sha) do
    full_name = "acme/forgejo-#{id}"

    %{
      "action" => "synchronized",
      "repository" => %{"id" => id},
      "sender" => %{"login" => "forgejo-reviewer"},
      "pull_request" => %{
        "draft" => false,
        "head" => %{"sha" => sha, "repo" => %{"full_name" => full_name}},
        "base" => %{"ref" => "main", "repo" => %{"full_name" => full_name}}
      }
    }
  end

  defp provider_id(payload, :gitlab), do: get_in(payload, ["project", "id"])
  defp provider_id(payload, :forgejo), do: get_in(payload, ["repository", "id"])
  defp event_sha(payload, :gitlab, :push), do: payload["after"]

  defp event_sha(payload, :gitlab, :pull_request),
    do: get_in(payload, ["object_attributes", "last_commit", "id"])

  defp event_sha(payload, :forgejo, :push), do: payload["after"]

  defp event_sha(payload, :forgejo, :pull_request),
    do: get_in(payload, ["pull_request", "head", "sha"])
end
