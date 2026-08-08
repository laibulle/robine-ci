defmodule Robine.Storage.StorageLifecycleTest do
  use Robine.DataCase, async: false

  alias Robine.Runtime.Dependencies
  alias Robine.Storage
  alias Robine.Adapters.Storage.LocalBlobStore

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
end
