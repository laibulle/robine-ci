defmodule Robine.Repositories.GitHubDeliveryTest do
  use Robine.DataCase, async: false

  import Ecto.Query

  alias Robine.Adapters.Background.ReconcileGitHubChecksWorker

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    Attempt,
    GitHubCheck,
    GitHubDelivery,
    Job,
    LogChunk,
    Pipeline,
    WorkflowRevision
  }

  alias Robine.{Repositories, Storage}
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
             workflow_dispatch:
               inputs:
                 environment:
                   type: choice
                   required: true
                   options: [staging, production]
                 version:
                   type: string
                   required: true
                 dry_run:
                   type: boolean
                   default: true
           jobs:
             test:
               image: postgres:18-alpine
               steps:
                 - name: Test
                   run: "true"
           """
         },
         %{
           path: ".robine-ci/workflows/release.yml",
           content: """
           version: 1
           name: Release
           on:
             push:
               tags: ["v*"]
           jobs:
             package:
               image: postgres:18-alpine
               steps:
                 - run: "true"
           """
         }
       ]}
    end

    @impl true
    def source_files(_repository, _sha), do: {:ok, [{"README.md", "source"}]}

    @impl true
    def default_branch_head(repository) do
      sha = String.duplicate("b", 40)
      send(self(), {:default_branch_head, repository.full_name, "main", sha})
      {:ok, %{branch: "main", sha: sha}}
    end

    @impl true
    def upsert_check(repository, check) do
      failures = Process.get({__MODULE__, :check_failures}, 0)

      if failures > 0 do
        Process.put({__MODULE__, :check_failures}, failures - 1)
        {:error, :temporary_provider_failure}
      else
        send(self(), {:upsert_check, repository.full_name, check})
        {:ok, :erlang.phash2(check.external_id)}
      end
    end

    @impl true
    def installation_permissions(_repository),
      do:
        {:ok,
         %{
           "metadata" => "read",
           "contents" => "write",
           "pull_requests" => "read",
           "checks" => "write"
         }}

    @impl true
    def publish_release(repository, release) do
      send(self(), {:publish_release, repository.full_name, release})
      :ok
    end
  end

  defmodule ReusableGitHub do
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
           name: Composed CI
           on:
             push: {branches: [main]}
             workflow_dispatch:
               inputs:
                 environment:
                   type: choice
                   required: true
                   options: [staging, production]
           includes:
             quality:
               path: .robine-ci/workflows/quality.yml
               inputs:
                 runtime: "3.22"
           jobs:
             package:
               image: alpine:3.22
               needs: quality--test
               steps:
                 - run: echo package
           """
         },
         %{
           path: ".robine-ci/workflows/quality.yml",
           content: """
           version: 1
           name: Quality
           on:
             workflow_call:
               inputs:
                 runtime:
                   type: choice
                   required: true
                   options: ["3.21", "3.22"]
           jobs:
             test:
               image: alpine:3.22
               steps:
                 - run: echo test
           """
         }
       ]}
    end

    @impl true
    def source_files(_repository, _sha), do: {:ok, []}

    @impl true
    def default_branch_head(repository) do
      sha = String.duplicate("a", 40)
      send(self(), {:default_branch_head, repository.full_name, "main", sha})
      {:ok, %{branch: "main", sha: sha}}
    end

    @impl true
    def upsert_check(_repository, check), do: {:ok, :erlang.phash2(check.external_id)}
    @impl true
    def installation_permissions(_repository), do: {:ok, %{}}
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

  test "keeps equal project IDs and names distinct across source-control providers" do
    context = context_with_fake_github()
    provider_id = 9_999

    assert {:ok, github} =
             Repositories.register_source_control_repository(
               %{
                 provider: :github,
                 provider_id: provider_id,
                 installation_id: 42,
                 full_name: "acme/shared"
               },
               context
             )

    assert {:ok, gitlab} =
             Repositories.register_source_control_repository(
               %{provider: :gitlab, provider_id: provider_id, full_name: "acme/shared"},
               context
             )

    assert {:ok, forgejo} =
             Repositories.register_source_control_repository(
               %{provider: :forgejo, provider_id: provider_id, full_name: "acme/shared"},
               context
             )

    assert MapSet.new([github.id, gitlab.id, forgejo.id]) |> MapSet.size() == 3

    assert {:ok, repositories} = Repositories.list_repositories(%{}, context)
    assert Enum.map(repositories, & &1.provider) |> Enum.sort() == [:forgejo, :github, :gitlab]

    repository_port = context.dependencies.repositories.repository

    assert {:ok, stored_gitlab} =
             repository_port.get_by_provider(:gitlab, "default", provider_id)

    assert stored_gitlab.id == gitlab.id
    assert stored_gitlab.full_name == "acme/shared"
  end

  test "resolves reusable jobs from the same event SHA and persists every included source" do
    context = context_with_github(ReusableGitHub)
    provider_id = 42_424_243
    repository = register(context, provider_id)
    sha = String.duplicate("a", 40)

    accept(
      "reusable-push",
      "push",
      %{
        "repository" => %{"id" => provider_id},
        "after" => sha,
        "ref" => "refs/heads/main"
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(%{delivery_id: "reusable-push"}, context)

    repository_id = repository.id
    assert Repo.get!(Pipeline, pipeline_id).repository_id == repository_id

    jobs =
      Repo.all(from job in Job, where: job.pipeline_id == ^pipeline_id, order_by: job.job_key)

    assert Enum.map(jobs, & &1.job_key) == ["package", "quality--test"]
    assert Enum.find(jobs, &(&1.job_key == "package")).needs == ["quality--test"]

    reusable = Enum.find(jobs, &(&1.job_key == "quality--test"))
    assert reusable.execution_spec["env"]["ROBINE_CALL_INPUT_RUNTIME"] == "3.22"

    revision =
      Repo.one!(from stored in WorkflowRevision, where: stored.pipeline_id == ^pipeline_id)

    included = revision.included_sources[".robine-ci/workflows/quality.yml"]
    assert included["source"] =~ "workflow_call"
    assert included["digest"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "manual launch resolves the same reusable graph at the displayed exact head" do
    context = context_with_github(ReusableGitHub)
    repository = register(context, 42_424_244)
    sha = String.duplicate("a", 40)

    assert {:ok, %{commit_sha: ^sha, workflows: [workflow]}} =
             Repositories.list_manual_workflows(%{repository_id: repository.id}, context)

    assert workflow.path == ".robine-ci/workflows/ci.yml"

    assert {:ok, %{pipeline: pipeline, commit_sha: ^sha}} =
             Repositories.launch_manual_workflow(
               %{
                 repository_id: repository.id,
                 workflow_path: workflow.path,
                 request_id: "reusable-manual",
                 inputs: %{"environment" => "production"}
               },
               context
             )

    jobs = Repo.all(from job in Job, where: job.pipeline_id == ^pipeline.id)
    assert Enum.map(jobs, & &1.job_key) |> Enum.sort() == ["package", "quality--test"]

    reusable = Enum.find(jobs, &(&1.job_key == "quality--test"))
    assert reusable.execution_spec["env"]["ROBINE_CALL_INPUT_RUNTIME"] == "3.22"
    assert reusable.execution_spec["env"]["ROBINE_INPUT_ENVIRONMENT"] == "production"

    revision =
      Repo.one!(from stored in WorkflowRevision, where: stored.pipeline_id == ^pipeline.id)

    assert revision.included_sources[".robine-ci/workflows/quality.yml"]["source"] =~
             "workflow_call"
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

  test "processes a same-repository pull request from its exact head commit" do
    context = context_with_fake_github()
    provider_id = 45_454_545
    repository = register(context, provider_id)
    sha = String.duplicate("3", 40)
    delivery_id = "pull-request-delivery"

    accept(
      delivery_id,
      "pull_request",
      %{
        "action" => "synchronize",
        "repository" => %{"id" => provider_id},
        "sender" => %{"login" => "octocat"},
        "pull_request" => %{
          "draft" => false,
          "head" => %{"sha" => sha, "repo" => %{"full_name" => "acme/widget"}},
          "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/widget"}}
        }
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id], commit_sha: ^sha}} =
             Repositories.process_github_delivery(%{delivery_id: delivery_id}, context)

    assert_receive {:workflow_files, "acme/widget", ^sha}

    assert %Pipeline{
             id: ^pipeline_id,
             repository_id: repository_id,
             commit_sha: ^sha,
             trigger: "pull_request",
             actor: "github:octocat"
           } = Repo.get!(Pipeline, pipeline_id)

    assert repository_id == repository.id
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

  test "creates and idempotently publishes a retained release payload for a version tag" do
    context = context_with_fake_github()
    repository = register(context, 43_434_344)
    sha = String.duplicate("a", 40)

    accept(
      "tag-release-delivery",
      "push",
      %{
        "repository" => %{"id" => repository.provider_id},
        "after" => sha,
        "ref" => "refs/tags/v0.1.0",
        "sender" => %{"login" => "octocat"}
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(
               %{delivery_id: "tag-release-delivery"},
               context
             )

    pipeline = Repo.get!(Pipeline, pipeline_id)
    assert pipeline.trigger == "tag"
    assert pipeline.inputs == %{"tag" => "v0.1.0"}

    pipeline
    |> Pipeline.changeset(%{
      status: :succeeded,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now()
    })
    |> Repo.update!()

    job = Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline_id)
    job |> Job.changeset(%{status: :succeeded}) |> Repo.update!()

    attempt_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    %Attempt{}
    |> Attempt.changeset(%{
      id: attempt_id,
      job_id: job.id,
      number: 1,
      idempotency_token: Ecto.UUID.generate(),
      status: :succeeded,
      lease_expires_at: DateTime.add(now, 60, :second),
      last_sequence: 1
    })
    |> Repo.insert!()

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository.id,
                 attempt_id: attempt_id,
                 name: "github-release",
                 content: "release-payload"
               },
               context
             )

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert_receive {:publish_release, "acme/widget",
                    %{
                      tag: "v0.1.0",
                      sha: ^sha,
                      asset_name: "robine-v0.1.0-release-assets.tar.gz",
                      content: "release-payload"
                    }}

    assert :ok = Robine.Adapters.Storage.LocalBlobStore.delete(artifact.digest)
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

  test "discovers and idempotently launches a typed manual workflow at the exact default head" do
    context = context_with_fake_github()
    repository = register(context, 61_616_161)
    sha = String.duplicate("b", 40)

    assert {:ok, %{branch: "main", commit_sha: ^sha, workflows: [workflow]}} =
             Repositories.list_manual_workflows(%{repository_id: repository.id}, context)

    assert workflow.name == "CI"
    assert workflow.path == ".robine-ci/workflows/ci.yml"
    assert workflow.inputs["environment"].type == :choice
    assert workflow.inputs["dry_run"].default == "true"
    assert_receive {:default_branch_head, "acme/widget", "main", ^sha}
    assert_receive {:workflow_files, "acme/widget", ^sha}

    launch = %{
      repository_id: repository.id,
      workflow_path: workflow.path,
      request_id: "manual-request-1",
      inputs: %{"environment" => "production", "version" => "1.2.3"}
    }

    assert {:ok, %{pipeline: first, branch: "main", commit_sha: ^sha}} =
             Repositories.launch_manual_workflow(launch, context)

    assert {:ok, %{pipeline: duplicate}} = Repositories.launch_manual_workflow(launch, context)
    assert duplicate.id == first.id

    stored = Repo.get!(Pipeline, first.id)
    assert stored.trigger == "workflow_dispatch"
    assert stored.actor == "admin"
    assert stored.commit_sha == sha

    assert stored.inputs == %{
             "dry_run" => "true",
             "environment" => "production",
             "version" => "1.2.3"
           }

    job = Repo.one!(from job in Job, where: job.pipeline_id == ^first.id)
    assert job.execution_spec["env"]["ROBINE_INPUT_ENVIRONMENT"] == "production"
    assert job.execution_spec["env"]["ROBINE_INPUT_VERSION"] == "1.2.3"
    assert job.execution_spec["env"]["ROBINE_INPUT_DRY_RUN"] == "true"

    audit =
      Repo.one!(
        from event in AuditEvent,
          where: event.target_id == ^first.id,
          order_by: [asc: event.occurred_at],
          limit: 1
      )

    assert audit.action == "workflow.manual_launch"
    assert audit.actor_id == "admin"
    assert audit.metadata["repository_id"] == repository.id
    assert audit.metadata["workflow_path"] == workflow.path
    assert audit.metadata["commit_sha"] == sha
    assert audit.metadata["input_count"] == 3
    refute inspect(audit.metadata) =~ "production"
    refute inspect(audit.metadata) =~ "1.2.3"

    assert Repo.aggregate(from(pipeline in Pipeline, where: pipeline.id == ^first.id), :count) ==
             1

    assert {:error, :idempotency_conflict} =
             Repositories.launch_manual_workflow(
               put_in(launch, [:inputs, "version"], "2.0.0"),
               context
             )

    assert Repo.aggregate(from(event in AuditEvent, where: event.target_id == ^first.id), :count) ==
             2

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: first.id}, context)

    assert_receive {:upsert_check, "acme/widget",
                    %{
                      external_id: "pipeline:" <> _,
                      output: %{
                        summary: "Pipeline is created. Trigger: manual workflow dispatch."
                      }
                    }}
  end

  test "manual launch rejects invalid values and forged viewer requests without persistence" do
    context = context_with_fake_github()
    repository = register(context, 60_606_060)
    before_count = Repo.aggregate(Pipeline, :count)

    input = %{
      repository_id: repository.id,
      workflow_path: ".robine-ci/workflows/ci.yml",
      request_id: "invalid-manual",
      inputs: %{"environment" => "unknown", "version" => "1.0.0"}
    }

    assert {:error, {:manual_input, "environment", :invalid_choice}} =
             Repositories.launch_manual_workflow(input, context)

    assert {:error, {:manual_input, "version", :required}} =
             Repositories.launch_manual_workflow(
               %{input | inputs: %{"environment" => "staging"}, request_id: "missing-required"},
               context
             )

    assert {:error, :manual_workflow_not_found} =
             Repositories.launch_manual_workflow(
               %{input | workflow_path: ".robine-ci/workflows/deleted.yml", request_id: "stale"},
               context
             )

    viewer_context =
      %{context | actor: %{id: "viewer", role: :viewer}}

    assert {:error, :forbidden} = Repositories.launch_manual_workflow(input, viewer_context)

    repository_schema =
      Repo.get!(Robine.Adapters.Persistence.Postgres.Schemas.GitHubRepository, repository.id)

    repository_schema |> Ecto.Changeset.change(trusted: false) |> Repo.update!()

    assert {:error, :untrusted_repository} =
             Repositories.launch_manual_workflow(%{input | request_id: "untrusted"}, context)

    assert Repo.aggregate(Pipeline, :count) == before_count
  end

  test "projects failed jobs with stable log links and failure conclusions" do
    context = context_with_fake_github()
    provider_id = 63_636_363
    _repository = register(context, provider_id)
    sha = String.duplicate("6", 40)

    accept(
      "failed-check-delivery",
      "push",
      %{
        "repository" => %{"id" => provider_id},
        "after" => sha,
        "ref" => "refs/heads/main"
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(
               %{delivery_id: "failed-check-delivery"},
               context
             )

    job = Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline_id)

    Repo.update_all(from(pipeline in Pipeline, where: pipeline.id == ^pipeline_id),
      set: [status: :failed]
    )

    Repo.update_all(from(stored_job in Job, where: stored_job.id == ^job.id),
      set: [status: :failed]
    )

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert_receive {:upsert_check, "acme/widget",
                    %{
                      external_id: pipeline_external_id,
                      status: :completed,
                      conclusion: :failure,
                      details_url: pipeline_url
                    }}

    assert_receive {:upsert_check, "acme/widget",
                    %{
                      external_id: job_external_id,
                      status: :completed,
                      conclusion: :failure,
                      details_url: job_url
                    }}

    assert pipeline_external_id == "pipeline:#{pipeline_id}"
    assert pipeline_url == "http://localhost:4004/pipelines/#{pipeline_id}"
    assert job_external_id == "job:#{job.id}"
    assert job_url == "http://localhost:4004/pipelines/#{pipeline_id}/jobs/#{job.id}"
  end

  test "projects a retained coverage marker into pipeline and job check summaries" do
    context = context_with_fake_github()
    provider_id = 62_626_262
    _repository = register(context, provider_id)

    accept(
      "coverage-check-delivery",
      "push",
      %{
        "repository" => %{"id" => provider_id},
        "after" => String.duplicate("5", 40),
        "ref" => "refs/heads/main"
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(
               %{delivery_id: "coverage-check-delivery"},
               context
             )

    job = Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline_id)
    now = DateTime.utc_now()
    attempt_id = Ecto.UUID.generate()

    Repo.update_all(from(pipeline in Pipeline, where: pipeline.id == ^pipeline_id),
      set: [status: :succeeded, started_at: now, finished_at: now]
    )

    Repo.update_all(from(stored_job in Job, where: stored_job.id == ^job.id),
      set: [status: :succeeded]
    )

    %Attempt{}
    |> Attempt.changeset(%{
      id: attempt_id,
      job_id: job.id,
      number: 1,
      idempotency_token: Ecto.UUID.generate(),
      status: :succeeded,
      lease_expires_at: DateTime.add(now, 60, :second),
      last_sequence: 1
    })
    |> Repo.insert!()

    %LogChunk{}
    |> LogChunk.changeset(%{
      attempt_id: attempt_id,
      sequence: 1,
      phase: "execution",
      stream: "stdout",
      step_position: 4,
      step_name: "Run project verification and coverage",
      step_status: "succeeded",
      exit_code: 0,
      duration_ms: 1,
      content: "ROBINE_COVERAGE total=75.3 threshold=75 report=coverage-report\n"
    })
    |> Repo.insert!()

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert_receive {:upsert_check, "acme/widget",
                    %{
                      external_id: "pipeline:" <> ^pipeline_id,
                      output: %{summary: pipeline_summary}
                    }}

    assert pipeline_summary =~ "### Coverage"
    assert pipeline_summary =~ "**75.3%** (threshold 75%)"
    assert pipeline_summary =~ "[Download report](http://localhost:4004/pipelines/"

    assert_receive {:upsert_check, "acme/widget",
                    %{
                      external_id: "job:" <> _job_id,
                      output: %{summary: job_summary}
                    }}

    assert job_summary =~ "Coverage: **75.3%**"
    assert job_summary =~ "[Download `coverage-report`](http://localhost:4004/pipelines/"
  end

  test "projects skipped jobs as distinct neutral checks" do
    context = context_with_fake_github()
    provider_id = 65_656_565
    _repository = register(context, provider_id)

    accept(
      "skipped-check-delivery",
      "push",
      %{
        "repository" => %{"id" => provider_id},
        "after" => String.duplicate("8", 40),
        "ref" => "refs/heads/main"
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(
               %{delivery_id: "skipped-check-delivery"},
               context
             )

    job = Repo.one!(from job in Job, where: job.pipeline_id == ^pipeline_id)

    matrix_execution =
      job.execution_spec
      |> Map.put("base_id", "test")
      |> Map.put("matrix_values", %{"otp" => "27"})

    Repo.update_all(from(stored in Job, where: stored.id == ^job.id),
      set: [status: :skipped, execution_spec: matrix_execution]
    )

    assert {:ok, 2} = Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert_receive {:upsert_check, "acme/widget",
                    %{
                      external_id: "job:" <> _job_id,
                      status: :completed,
                      conclusion: :neutral,
                      output: %{summary: "Job is skipped. Matrix: otp=27"}
                    }}
  end

  test "a temporary check API failure preserves local state and reconciles later" do
    previous_adapter = Application.fetch_env!(:robine, :github_adapter)
    Application.put_env(:robine, :github_adapter, FakeGitHub)
    on_exit(fn -> Application.put_env(:robine, :github_adapter, previous_adapter) end)

    context = context_with_fake_github()
    provider_id = 64_646_464
    _repository = register(context, provider_id)
    sha = String.duplicate("7", 40)

    accept(
      "temporary-failure-delivery",
      "push",
      %{
        "repository" => %{"id" => provider_id},
        "after" => sha,
        "ref" => "refs/heads/main"
      },
      context
    )

    assert {:ok, %{pipeline_ids: [pipeline_id]}} =
             Repositories.process_github_delivery(
               %{delivery_id: "temporary-failure-delivery"},
               context
             )

    Process.put({FakeGitHub, :check_failures}, 1)

    assert {:error, :temporary_provider_failure} =
             Repositories.sync_github_checks(%{pipeline_id: pipeline_id}, context)

    assert Repo.get!(Pipeline, pipeline_id).commit_sha == sha
    assert Repo.aggregate(GitHubCheck, :count) == 0

    assert :ok = ReconcileGitHubChecksWorker.perform(%Oban.Job{})
    assert Repo.aggregate(GitHubCheck, :count) == 2
    assert_receive {:upsert_check, "acme/widget", %{external_id: "pipeline:" <> ^pipeline_id}}
    assert_receive {:upsert_check, "acme/widget", %{external_id: "job:" <> _job_id}}
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
    context_with_github(FakeGitHub)
  end

  defp context_with_github(github) do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "github-test")
    dependencies = context.dependencies.repositories
    fake = %{dependencies | source_control: github}
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
