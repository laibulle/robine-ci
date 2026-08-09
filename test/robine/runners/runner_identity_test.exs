defmodule Robine.Runners.RunnerIdentityTest do
  use Robine.DataCase, async: false

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    RemoteRunner,
    RunnerCredential,
    RunnerEnrollmentToken
  }

  alias Robine.{Repo, Runners}
  alias Robine.Runtime.Dependencies

  test "enrolls once without retaining plaintext secrets, authenticates, and revokes" do
    admin_context = context(%{id: "admin-1", role: :administrator})

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)
    assert String.starts_with?(enrollment.token, "rbe_")
    assert DateTime.diff(enrollment.expires_at, DateTime.utc_now(), :second) in 895..900

    stored_enrollment = Repo.get!(RunnerEnrollmentToken, enrollment.id)
    refute stored_enrollment.token_digest == enrollment.token
    refute inspect(stored_enrollment) =~ enrollment.token

    runner_context = context(%{id: "anonymous", role: :runner})

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "builder-eu-1"}, runner_context)

    assert String.starts_with?(identity.credential, "rrc_")
    assert Repo.get!(RemoteRunner, identity.runner_id).name == "builder-eu-1"

    stored_credential = Repo.one!(from credential in RunnerCredential, limit: 1)
    refute stored_credential.credential_digest == identity.credential
    refute inspect(stored_credential) =~ identity.credential
    assert Repo.get!(RunnerEnrollmentToken, enrollment.id).consumed_at

    assert {:error, :invalid_enrollment_token} =
             Runners.enroll(%{token: enrollment.token, name: "replay"}, runner_context)

    assert {:ok, authenticated} =
             Runners.authenticate(
               %{runner_id: identity.runner_id, credential: identity.credential},
               runner_context
             )

    assert authenticated.runner_id == identity.runner_id
    assert Repo.get!(RemoteRunner, identity.runner_id).last_authenticated_at

    assert {:ok, rotated} =
             Runners.rotate_credential(%{runner_id: identity.runner_id}, admin_context)

    assert rotated.runner_id == identity.runner_id
    assert rotated.credential != identity.credential
    assert Repo.aggregate(RunnerCredential, :count) == 2

    assert Repo.one!(
             from credential in RunnerCredential, where: not is_nil(credential.expires_at)
           )

    assert {:ok, _runner} =
             Runners.authenticate(
               %{runner_id: identity.runner_id, credential: identity.credential},
               runner_context
             )

    assert {:ok, _runner} =
             Runners.authenticate(
               %{runner_id: identity.runner_id, credential: rotated.credential},
               runner_context
             )

    assert :ok = Runners.revoke(%{runner_id: identity.runner_id}, admin_context)
    assert Repo.get!(RemoteRunner, identity.runner_id).admin_state == :revoked
    assert Repo.one!(from credential in RunnerCredential, limit: 1).revoked_at

    assert {:error, :unauthorized} =
             Runners.authenticate(
               %{runner_id: identity.runner_id, credential: identity.credential},
               runner_context
             )

    actions =
      Repo.all(from event in AuditEvent, order_by: event.occurred_at, select: event.action)

    assert "runner.enrollment_created" in actions
    assert "runner.enrolled" in actions
    assert "runner.credential_rotated" in actions
    assert "runner.revoked" in actions
    assert "runner.authentication_failed" in actions
  end

  test "requires an administrator to create or revoke runner identities" do
    maintainer_context = context(%{id: "maintainer-1", role: :maintainer})

    assert {:error, :forbidden} =
             Runners.create_enrollment_token(%{}, maintainer_context)

    assert {:error, :forbidden} =
             Runners.revoke(%{runner_id: Ecto.UUID.generate()}, maintainer_context)

    assert {:error, :forbidden} =
             Runners.rotate_credential(%{runner_id: Ecto.UUID.generate()}, maintainer_context)
  end

  test "rejects malformed credentials with the same public error" do
    runner_context = context(%{id: "anonymous", role: :runner})

    assert {:error, :unauthorized} =
             Runners.authenticate(
               %{runner_id: "not-a-uuid", credential: "not-a-credential"},
               runner_context
             )

    assert Repo.one!(from event in AuditEvent, limit: 1).metadata["claimed_runner_id_valid"] ==
             false
  end

  test "rejects an expired enrollment token" do
    admin_context = context(%{id: "admin-expiry", role: :administrator})
    runner_context = context(%{id: "anonymous", role: :runner})
    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    Repo.get!(RunnerEnrollmentToken, enrollment.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :invalid_enrollment_token} =
             Runners.enroll(%{token: enrollment.token, name: "too-late"}, runner_context)

    assert Repo.aggregate(RemoteRunner, :count) == 0
    refute Repo.get!(RunnerEnrollmentToken, enrollment.id).consumed_at
  end

  test "concurrent enrollment attempts consume a token only once" do
    admin_context = context(%{id: "admin-race", role: :administrator})
    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          Runners.enroll(
            %{token: enrollment.token, name: "race-#{index}"},
            context(%{id: "anonymous", role: :runner})
          )
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_enrollment_token})) == 1
    assert Repo.aggregate(RemoteRunner, :count) == 1
    assert Repo.aggregate(RunnerCredential, :count) == 1
  end

  test "lists, labels, drains, and enables fleet capacity through audited use cases" do
    admin_context = context(%{id: "fleet-admin", role: :administrator})
    anonymous_context = context(%{id: "anonymous", role: :runner})

    assert {:ok, %{status: :available, local_capacity: true}} =
             Runners.explain_capacity(%{labels: ["docker"]}, admin_context)

    assert {:ok, %{status: :absent}} =
             Runners.explain_capacity(%{labels: ["docker", "gpu"]}, admin_context)

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "fleet-old"}, anonymous_context)

    runner_context = context(%{id: identity.runner_id, role: :runner})

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{
                   "docker" => true,
                   "os" => "linux",
                   "architecture" => "x86_64",
                   "concurrency" => 2
                 }
               },
               runner_context
             )

    assert {:ok, updated} =
             Runners.update_runner(
               %{
                 runner_id: identity.runner_id,
                 name: "fleet-gpu",
                 labels: ["gpu", "eu-west"],
                 admin_state: :draining
               },
               admin_context
             )

    assert updated.name == "fleet-gpu"
    assert updated.labels == ["gpu", "eu-west"]
    assert updated.admin_state == :draining
    assert {:error, :none} = Runners.select_available(%{}, admin_context)

    assert {:ok, [runner]} = Runners.list_fleet(%{}, admin_context)
    assert runner.connectivity == :online
    assert runner.admin_state == :draining
    assert runner.available_slots == 2
    assert runner.capabilities["os"] == "linux"

    assert {:ok, %{status: :draining}} =
             Runners.explain_capacity(%{labels: ["docker", "gpu"]}, admin_context)

    assert {:ok, %{admin_state: :enabled}} =
             Runners.update_runner(
               %{runner_id: identity.runner_id, admin_state: :enabled},
               admin_context
             )

    assert {:ok, %{id: runner_id}} = Runners.select_available(%{}, admin_context)
    assert runner_id == identity.runner_id

    assert {:ok, %{status: :available}} =
             Runners.explain_capacity(%{labels: ["docker", "gpu"]}, admin_context)

    assert {:error, :invalid_runner_labels} =
             Runners.update_runner(
               %{runner_id: identity.runner_id, labels: ["GPU Large"]},
               admin_context
             )

    audit =
      Repo.one!(
        from event in AuditEvent,
          where: event.action == "runner.configuration_updated",
          order_by: [desc: event.occurred_at],
          limit: 1
      )

    assert audit.metadata["before"]["admin_state"] == "draining"
    assert audit.metadata["after"]["admin_state"] == "enabled"
  end

  defp context(actor), do: Dependencies.context(actor, Ecto.UUID.generate())
end
