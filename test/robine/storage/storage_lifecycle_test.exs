defmodule Robine.Storage.StorageLifecycleTest do
  use Robine.DataCase, async: false

  alias Robine.{Pipelines, Storage}
  alias Robine.Runtime.Dependencies
  alias Robine.Adapters.Storage.LocalBlobStore

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Artifact,
    GitHubRepository,
    StorageGcCandidate
  }

  alias Robine.Repo

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

    assert Repo.aggregate(StorageGcCandidate, :count) == 1

    assert :ok = LocalBlobStore.delete(first.digest)
    assert :ok = LocalBlobStore.delete(second.digest)
    assert :ok = LocalBlobStore.delete(:crypto.hash(:sha256, "x") |> Base.encode16(case: :lower))
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
             Storage.download_manual_artifact(
               %{repository_id: repository_id, artifact_id: artifact.id},
               viewer
             )

    assert {:error, :not_found} =
             Storage.download_artifact(
               %{repository_id: Ecto.UUID.generate(), artifact_id: artifact.id},
               viewer
             )

    assert :ok = LocalBlobStore.delete(artifact.digest)
  end

  test "accepts lazy content streams at the application boundary" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "maintainer", role: :maintainer}, "streamed-artifact")
    content_stream = Stream.map(["streamed-", "artifact"], & &1)

    assert {:ok, artifact} =
             Storage.upload_artifact(
               %{
                 repository_id: repository_id,
                 attempt_id: Ecto.UUID.generate(),
                 name: "streamed.txt",
                 content_stream: content_stream
               },
               context
             )

    assert artifact.size == byte_size("streamed-artifact")

    assert {:ok, %{content: "streamed-artifact"}} =
             Storage.download_artifact(
               %{repository_id: repository_id, artifact_id: artifact.id},
               context
             )

    assert {:error, {:invalid_cache, :content}} =
             Storage.save_cache(
               %{repository_id: repository_id, key: "invalid-stream", content_stream: self()},
               context
             )

    assert :ok = LocalBlobStore.delete(artifact.digest)
  end

  test "retains manual artifact provenance without inventing a CI attempt" do
    repository_id = trusted_repository!()
    uploader_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: uploader_id, role: :maintainer}, "manual-artifact")
    content = "signed-notarized-dmg"

    assert {:ok, first} =
             Storage.upload_manual_artifact(
               %{
                 repository_id: repository_id,
                 name: "Robine.dmg",
                 content_type: "application/x-apple-diskimage",
                 content_stream: Stream.map([content], & &1),
                 retention_seconds: 86_400
               },
               context
             )

    assert first.source == :manual
    assert first.uploaded_by_id == uploader_id
    assert first.content_type == "application/x-apple-diskimage"
    assert first.digest == :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    persisted = Repo.get!(Artifact, first.id)
    assert persisted.attempt_id == nil
    assert persisted.source == :manual
    assert persisted.uploaded_by_id == uploader_id

    assert {:ok, second} =
             Storage.upload_manual_artifact(
               %{
                 repository_id: repository_id,
                 name: "Robine.dmg",
                 content_type: "application/x-apple-diskimage",
                 content: content <> "-second"
               },
               context
             )

    viewer = %{context | actor: %{id: "viewer", role: :viewer}}

    assert {:ok, [listed_second, listed_first]} =
             Storage.list_manual_artifacts(%{repository_id: repository_id}, viewer)

    assert [listed_second.id, listed_first.id] == [second.id, first.id]

    assert {:ok, %{content: ^content, content_type: "application/x-apple-diskimage"}} =
             Storage.download_manual_artifact(
               %{repository_id: repository_id, artifact_id: first.id},
               viewer
             )

    assert {:error, :forbidden} =
             Storage.upload_manual_artifact(
               %{
                 repository_id: repository_id,
                 name: "forged.dmg",
                 content_type: "application/octet-stream",
                 content: "forged"
               },
               viewer
             )

    assert {:error, :repository_not_found} =
             Storage.upload_manual_artifact(
               %{
                 repository_id: Ecto.UUID.generate(),
                 name: "missing.dmg",
                 content_type: "application/octet-stream",
                 content: "missing"
               },
               context
             )

    assert :ok = LocalBlobStore.delete(first.digest)
    assert :ok = LocalBlobStore.delete(second.digest)
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

  defp trusted_repository! do
    id = Ecto.UUID.generate()
    provider_id = System.unique_integer([:positive])

    %GitHubRepository{}
    |> GitHubRepository.changeset(%{
      id: id,
      provider: :github,
      provider_instance: "default",
      provider_id: provider_id,
      installation_id: provider_id,
      owner: "acme",
      name: "manual-artifacts",
      full_name: "acme/manual-artifacts-#{provider_id}",
      trusted: true,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    id
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
