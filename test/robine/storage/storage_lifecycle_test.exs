defmodule Robine.Storage.StorageLifecycleTest do
  use Robine.DataCase, async: false

  alias Robine.{Pipelines, Storage}
  alias Robine.Runtime.Dependencies
  alias Robine.Adapters.Storage.LocalBlobStore

  test "atomically enforces repository and instance logical quotas" do
    previous = Application.fetch_env!(:robine, :storage_quotas)
    Application.put_env(:robine, :storage_quotas, instance_bytes: 10, repository_bytes: 6)
    on_exit(fn -> Application.put_env(:robine, :storage_quotas, previous) end)

    first_repository = Ecto.UUID.generate()
    second_repository = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "maintainer", role: :maintainer}, "quotas")

    assert {:ok, first} =
             Storage.upload_artifact(
               %{
                 repository_id: first_repository,
                 attempt_id: Ecto.UUID.generate(),
                 name: "first",
                 content: "123456"
               },
               context
             )

    assert {:error, {:quota_exceeded, :repository, 6}} =
             Storage.upload_artifact(
               %{
                 repository_id: first_repository,
                 attempt_id: Ecto.UUID.generate(),
                 name: "overflow",
                 content: "x"
               },
               context
             )

    assert {:ok, second} =
             Storage.save_cache(
               %{repository_id: second_repository, key: "four", content: "1234"},
               context
             )

    assert {:error, {:quota_exceeded, :instance, 10}} =
             Storage.save_cache(
               %{repository_id: second_repository, key: "overflow", content: "x"},
               context
             )

    assert :ok = LocalBlobStore.delete(first.digest)
    assert :ok = LocalBlobStore.delete(second.digest)
  end

  test "uploads immutable artifacts and returns digest-verified authorized content" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "maintainer", role: :maintainer}, "artifact")
    content = "artifact-#{Ecto.UUID.generate()}"

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository_id,
                 attempt_id: Ecto.UUID.generate(),
                 name: "test-report.txt",
                 content: content,
                 retention_seconds: 60
               },
               context
             )

    viewer = %{context | actor: %{id: "viewer", role: :viewer}}

    assert {:ok, download} =
             Storage.download_artifact(
               %{repository_id: repository_id, artifact_id: artifact.id},
               viewer
             )

    assert download.content == content
    assert download.digest == artifact.digest

    assert {:error, :not_found} =
             Storage.download_artifact(
               %{repository_id: Ecto.UUID.generate(), artifact_id: artifact.id},
               viewer
             )

    assert :ok = LocalBlobStore.delete(artifact.digest)
  end

  test "cache miss is successful and exact-key saves replace the prior complete entry" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "maintainer", role: :maintainer}, "cache")

    assert {:ok, :miss} =
             Storage.restore_cache(%{repository_id: repository_id, key: "mix-lock-v1"}, context)

    assert {:ok, first} =
             Storage.save_cache(
               %{repository_id: repository_id, key: "mix-lock-v1", content: "first"},
               context
             )

    assert {:ok, %{content: "first", digest: first_digest}} =
             Storage.restore_cache(%{repository_id: repository_id, key: "mix-lock-v1"}, context)

    assert first_digest == first.digest

    assert {:ok, second} =
             Storage.save_cache(
               %{repository_id: repository_id, key: "mix-lock-v1", content: "second"},
               context
             )

    assert second.digest != first.digest

    assert {:ok, %{content: "second", digest: second_digest}} =
             Storage.restore_cache(%{repository_id: repository_id, key: "mix-lock-v1"}, context)

    assert second_digest == second.digest
    assert :ok = LocalBlobStore.delete(first.digest)
    assert :ok = LocalBlobStore.delete(second.digest)
  end

  test "rejects path-shaped artifact names and invalid cache keys" do
    context = Dependencies.context(%{id: "maintainer", role: :maintainer}, "invalid-storage")

    assert {:error, {:invalid_artifact, :name}} =
             Storage.upload_artifact(
               %{
                 repository_id: Ecto.UUID.generate(),
                 attempt_id: Ecto.UUID.generate(),
                 name: "../../escape",
                 content: "content"
               },
               context
             )

    assert {:error, {:invalid_cache, :key}} =
             Storage.save_cache(
               %{repository_id: Ecto.UUID.generate(), key: "", content: "content"},
               context
             )
  end

  test "downloads only retained artifacts from a declared successful dependency" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "admin", role: :administrator}, "dependency-artifact")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: repository_id,
                 workflow_name: "CI",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{
                   "build" => %{
                     needs: [],
                     image: "alpine:3.22",
                     steps: [%{name: "build", kind: :run, value: "true"}]
                   },
                   "test" => %{
                     needs: ["build"],
                     image: "alpine:3.22",
                     steps: [%{name: "test", kind: :run, value: "true"}]
                   }
                 }
               },
               context
             )

    assert {:ok, _} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)
    advance(attempt, :preparing, 1, context)
    advance(attempt, :running, 2, context)

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository_id,
                 attempt_id: attempt.id,
                 name: "release",
                 content: "verified archive"
               },
               context
             )

    advance(attempt, :succeeded, 3, context)

    assert {:ok, %{content: "verified archive"}} =
             Storage.download_dependency_artifact(
               %{
                 pipeline_id: pipeline.id,
                 from_job: "build",
                 name: "release",
                 needs: ["build"]
               },
               context
             )

    assert {:error, :undeclared_dependency} =
             Storage.download_dependency_artifact(
               %{
                 pipeline_id: pipeline.id,
                 from_job: "build",
                 name: "release",
                 needs: []
               },
               context
             )

    assert :ok = LocalBlobStore.delete(artifact.digest)
  end

  defp advance(attempt, status, sequence, context) do
    assert {:ok, _} =
             Pipelines.record_runner_event(
               %{
                 idempotency_token: attempt.idempotency_token,
                 sequence: sequence,
                 status: status
               },
               context
             )
  end
end
