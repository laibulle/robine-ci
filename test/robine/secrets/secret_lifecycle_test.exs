defmodule Robine.Secrets.SecretLifecycleTest do
  use Robine.DataCase, async: true
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{AuditEvent, Secret}
  alias Robine.Runtime.Dependencies
  alias Robine.Secrets
  alias Robine.Repo

  test "stores repository secrets encrypted, audits writes, and resolves explicitly" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "maintainer", role: :maintainer}, "secret-test")

    assert {:ok, metadata} =
             Secrets.store_secret(
               %{
                 name: "REGISTRY_TOKEN",
                 value: "very-sensitive-token",
                 scope: :repository,
                 repository_id: repository_id
               },
               context
             )

    refute Map.has_key?(Map.from_struct(metadata), :value)
    stored = Repo.one!(Secret)
    refute stored.ciphertext =~ "very-sensitive-token"
    assert Repo.aggregate(AuditEvent, :count) == 1

    system_context = %{context | actor: %{id: "runner", role: :administrator}}

    assert {:ok, %{"REGISTRY_TOKEN" => "very-sensitive-token"}} =
             Secrets.resolve_secrets(
               %{repository_id: repository_id, names: ["REGISTRY_TOKEN"]},
               system_context
             )

    assert {:error, {:secrets_missing, ["MISSING"]}} =
             Secrets.resolve_secrets(
               %{repository_id: repository_id, names: ["MISSING"]},
               system_context
             )
  end

  test "instance secrets require an administrator and explicit repository grants" do
    allowed = Ecto.UUID.generate()
    denied = Ecto.UUID.generate()
    maintainer = Dependencies.context(%{id: "maintainer", role: :maintainer}, "maintainer")

    input = %{
      name: "GLOBAL_TOKEN",
      value: "global-sensitive-token",
      scope: :instance,
      allowed_repository_ids: [allowed]
    }

    assert {:error, :forbidden} = Secrets.store_secret(input, maintainer)
    admin = %{maintainer | actor: %{id: "admin", role: :administrator}}
    assert {:ok, _metadata} = Secrets.store_secret(input, admin)

    assert {:ok, %{"GLOBAL_TOKEN" => "global-sensitive-token"}} =
             Secrets.resolve_secrets(%{repository_id: allowed, names: ["GLOBAL_TOKEN"]}, admin)

    assert {:error, {:secrets_missing, ["GLOBAL_TOKEN"]}} =
             Secrets.resolve_secrets(%{repository_id: denied, names: ["GLOBAL_TOKEN"]}, admin)
  end

  test "authenticated encryption rejects modified ciphertext" do
    repository_id = Ecto.UUID.generate()
    context = Dependencies.context(%{id: "admin", role: :administrator}, "tamper")

    {:ok, _} =
      Secrets.store_secret(
        %{
          name: "TOKEN",
          value: "sensitive-value",
          scope: :repository,
          repository_id: repository_id
        },
        context
      )

    secret = Repo.one!(from secret in Secret, limit: 1)
    <<first, rest::binary>> = secret.ciphertext

    secret
    |> Ecto.Changeset.change(ciphertext: <<Bitwise.bxor(first, 1), rest::binary>>)
    |> Repo.update!()

    assert {:error, {:secret_decryption_failed, "TOKEN", :authentication_failed}} =
             Secrets.resolve_secrets(%{repository_id: repository_id, names: ["TOKEN"]}, context)
  end
end
