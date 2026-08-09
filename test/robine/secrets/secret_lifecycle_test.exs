defmodule Robine.Secrets.SecretLifecycleTest do
  use Robine.DataCase, async: false
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{AuditEvent, Secret}
  alias Robine.Adapters.Security.AesGcmCipher
  alias Robine.Runtime.Dependencies
  alias Robine.Secrets
  alias Robine.Repo

  test "rejects oversized values before encryption or persistence" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "secret-size")

    assert {:error, {:invalid_secret, :value_too_large}} =
             Secrets.store_secret(
               %{
                 name: "OVERSIZED_TOKEN",
                 value: :binary.copy("x", 65_537),
                 scope: :repository,
                 repository_id: Ecto.UUID.generate()
               },
               context
             )

    assert Repo.aggregate(Secret, :count) == 0
  end

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

  test "system adapters can resolve encrypted instance credentials without repository grants" do
    admin =
      Dependencies.context(%{id: "admin", role: :administrator}, "instance-credential-resolution")

    assert {:ok, _metadata} =
             Secrets.store_secret(
               %{
                 name: "GITHUB_WEBHOOK_SECRET",
                 value: "database-webhook-secret",
                 scope: :instance,
                 allowed_repository_ids: []
               },
               admin
             )

    assert {:ok, %{"GITHUB_WEBHOOK_SECRET" => "database-webhook-secret"}} =
             Secrets.resolve_instance_secrets(%{names: ["GITHUB_WEBHOOK_SECRET"]}, admin)

    maintainer = %{admin | actor: %{id: "maintainer", role: :maintainer}}

    assert {:error, :forbidden} =
             Secrets.resolve_instance_secrets(%{names: ["GITHUB_WEBHOOK_SECRET"]}, maintainer)

    assert {:ok, "database-webhook-secret"} =
             Robine.Adapters.SourceControl.GitHubCredentials.fetch(:webhook_secret)
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

  test "cipher rejects malformed persisted envelopes without raising" do
    assert {:error, :invalid_ciphertext} =
             AesGcmCipher.decrypt(
               %{ciphertext: <<1>>, nonce: <<2>>, tag: <<3>>, key_version: 1},
               "aad"
             )
  end

  test "rotates mixed key versions in resumable audited batches" do
    telemetry_handler = "secret-rotation-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:robine, :secrets, :rotation],
        fn event, measurements, metadata, _config ->
          send(parent, {:secret_rotation_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    previous = Application.fetch_env!(:robine, :secret_keyring)
    old_key = :binary.copy(<<11>>, 32)
    new_key = :binary.copy(<<22>>, 32)
    Application.put_env(:robine, :secret_keyring, current_version: 1, keys: %{1 => old_key})
    on_exit(fn -> Application.put_env(:robine, :secret_keyring, previous) end)

    repository_id = Ecto.UUID.generate()
    admin = Dependencies.context(%{id: "admin", role: :administrator}, "key-rotation")

    for {name, value} <- [{"FIRST_TOKEN", "first-secret"}, {"SECOND_TOKEN", "second-secret"}] do
      assert {:ok, _metadata} =
               Secrets.store_secret(
                 %{name: name, value: value, scope: :repository, repository_id: repository_id},
                 admin
               )
    end

    Application.put_env(:robine, :secret_keyring,
      current_version: 2,
      keys: %{1 => old_key, 2 => new_key}
    )

    assert {:ok, _metadata} =
             Secrets.store_secret(
               %{
                 name: "CURRENT_TOKEN",
                 value: "current-secret",
                 scope: :repository,
                 repository_id: repository_id
               },
               admin
             )

    assert {:ok, %{rotated: 1, target_version: 2, complete: false, next_cursor: cursor}} =
             Secrets.rotate_keys(%{limit: 1}, admin)

    assert is_binary(cursor)
    assert Repo.aggregate(from(secret in Secret, where: secret.key_version == 1), :count) == 1

    assert {:ok, %{rotated: 1, target_version: 2, complete: true, next_cursor: nil}} =
             Secrets.rotate_keys(%{limit: 1, cursor: cursor}, admin)

    assert Repo.aggregate(from(secret in Secret, where: secret.key_version == 1), :count) == 0

    assert {:ok,
            %{
              "FIRST_TOKEN" => "first-secret",
              "SECOND_TOKEN" => "second-secret",
              "CURRENT_TOKEN" => "current-secret"
            }} =
             Secrets.resolve_secrets(
               %{
                 repository_id: repository_id,
                 names: ["FIRST_TOKEN", "SECOND_TOKEN", "CURRENT_TOKEN"]
               },
               admin
             )

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.action == "secret.key_rotated"),
             :count
           ) == 2

    for _rotation <- 1..2 do
      assert_receive {:secret_rotation_telemetry, event, measurements, metadata}
      telemetry_payload = inspect({event, measurements, metadata})
      refute telemetry_payload =~ "first-secret"
      refute telemetry_payload =~ "second-secret"
      refute telemetry_payload =~ "current-secret"
    end

    maintainer = %{admin | actor: %{id: "maintainer", role: :maintainer}}
    assert {:error, :forbidden} = Secrets.rotate_keys(%{}, maintainer)
  end
end
