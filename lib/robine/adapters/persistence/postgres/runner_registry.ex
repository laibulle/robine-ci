defmodule Robine.Adapters.Persistence.Postgres.RunnerRegistry do
  @moduledoc false
  @behaviour Robine.Runners.Ports.Registry

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    RemoteRunner,
    RunnerCredential,
    RunnerEnrollmentToken,
    Attempt
  }

  alias Robine.Repo
  alias Robine.Runners.Domain.Runner

  @unknown_runner_id "00000000-0000-0000-0000-000000000000"
  @active_attempts [:queued, :preparing, :running, :cancelling]

  @impl true
  def create_enrollment(%{audit: audit} = attributes) do
    Repo.transaction(fn ->
      enrollment_attributes = Map.delete(attributes, :audit)

      with {:ok, token} <-
             RunnerEnrollmentToken.changeset(%RunnerEnrollmentToken{}, enrollment_attributes)
             |> Repo.insert(),
           {:ok, _event} <-
             audit_event(
               audit,
               "runner.enrollment_created",
               "runner_enrollment_token",
               token.id,
               token.inserted_at,
               %{expires_at: token.expires_at}
             ) do
        :ok
      else
        {:error, changeset} -> Repo.rollback({:runner_persistence, changeset})
      end
    end)
    |> unwrap_transaction()
  end

  @impl true
  def consume_enrollment(token_digest, now, %Runner{} = runner, credential, audit) do
    Repo.transaction(fn ->
      token =
        Repo.one(
          from enrollment in RunnerEnrollmentToken,
            where:
              enrollment.token_digest == ^token_digest and is_nil(enrollment.consumed_at) and
                enrollment.expires_at > ^now,
            lock: "FOR UPDATE"
        )

      if token do
        with {:ok, runner_schema} <-
               RemoteRunner.changeset(%RemoteRunner{}, Map.from_struct(runner)) |> Repo.insert(),
             {:ok, _credential} <-
               RunnerCredential.changeset(
                 %RunnerCredential{},
                 Map.put(credential, :runner_id, runner.id)
               )
               |> Repo.insert(),
             {:ok, _token} <-
               token
               |> Ecto.Changeset.change(consumed_at: now, runner_id: runner.id)
               |> Repo.update(),
             {:ok, _event} <-
               audit_event(
                 audit,
                 "runner.enrolled",
                 "remote_runner",
                 runner.id,
                 now,
                 %{}
               ) do
          domain_runner(runner_schema)
        else
          {:error, changeset} -> Repo.rollback({:runner_persistence, changeset})
        end
      else
        Repo.rollback(:invalid_enrollment_token)
      end
    end)
  end

  @impl true
  def authentication_candidates(runner_id, now) do
    case Ecto.UUID.cast(runner_id) do
      :error ->
        {:error, :not_found}

      {:ok, runner_id} ->
        runner =
          Repo.one(
            from runner in RemoteRunner,
              where: runner.id == ^runner_id and runner.admin_state != :revoked
          )

        if runner do
          digests =
            Repo.all(
              from credential in RunnerCredential,
                where:
                  credential.runner_id == ^runner_id and is_nil(credential.revoked_at) and
                    (is_nil(credential.expires_at) or credential.expires_at > ^now),
                select: credential.credential_digest
            )

          {:ok, domain_runner(runner), digests}
        else
          {:error, :not_found}
        end
    end
  end

  @impl true
  def record_authentication(runner_id, authenticated_at) do
    {updated, _} =
      Repo.update_all(
        from(runner in RemoteRunner,
          where: runner.id == ^runner_id and runner.admin_state != :revoked
        ),
        set: [last_authenticated_at: authenticated_at, updated_at: authenticated_at]
      )

    if updated == 1, do: :ok, else: {:error, :not_found}
  end

  @impl true
  def record_session(runner_id, version, software_version, capabilities, now) do
    {updated, _} =
      Repo.update_all(
        from(runner in RemoteRunner,
          where: runner.id == ^runner_id and runner.admin_state != :revoked
        ),
        set: [
          protocol_version: version,
          software_version: software_version,
          capabilities: capabilities,
          last_seen_at: now,
          updated_at: now
        ]
      )

    if updated == 1, do: :ok, else: {:error, :unauthorized}
  end

  @impl true
  def heartbeat(runner_id, version, now) do
    {updated, _} =
      Repo.update_all(
        from(runner in RemoteRunner,
          where:
            runner.id == ^runner_id and runner.admin_state != :revoked and
              runner.protocol_version == ^version
        ),
        set: [last_seen_at: now, updated_at: now]
      )

    if updated == 1, do: :ok, else: {:error, :unauthorized}
  end

  @impl true
  def next_available(now) do
    stale_before = DateTime.add(now, -60, :second)

    active_counts =
      from attempt in Attempt,
        where: attempt.status in ^@active_attempts and not is_nil(attempt.runner_id),
        group_by: attempt.runner_id,
        select: %{runner_id: attempt.runner_id, active_count: count(attempt.id)}

    query =
      from runner in RemoteRunner,
        left_join: active in subquery(active_counts),
        on: fragment("? = ?::text", active.runner_id, runner.id),
        where:
          runner.admin_state == :enabled and runner.protocol_version == 1 and
            runner.last_seen_at >= ^stale_before and
            (fragment("COALESCE((?->>'docker')::boolean, false)", runner.capabilities) or
               fragment("COALESCE((?->>'native')::boolean, false)", runner.capabilities)) and
            fragment(
              "COALESCE(?, 0) < COALESCE(NULLIF(?->>'concurrency', '')::integer, 1)",
              active.active_count,
              runner.capabilities
            ),
        order_by: [asc: active.active_count, asc: runner.last_seen_at, asc: runner.id],
        limit: 1,
        select: %{
          id: runner.id,
          name: runner.name,
          capabilities: runner.capabilities,
          active_attempts: coalesce(active.active_count, 0)
        }

    case Repo.one(query) do
      nil -> {:error, :none}
      runner -> {:ok, runner}
    end
  end

  @impl true
  def get(runner_id) do
    case Repo.get(RemoteRunner, runner_id) do
      nil -> {:error, :not_found}
      runner -> {:ok, domain_runner(runner)}
    end
  end

  @impl true
  def list_fleet(now) do
    active_counts =
      from attempt in Attempt,
        where: attempt.status in ^@active_attempts and not is_nil(attempt.runner_id),
        group_by: attempt.runner_id,
        select: %{runner_id: attempt.runner_id, active_count: count(attempt.id)}

    runners =
      Repo.all(
        from runner in RemoteRunner,
          left_join: active in subquery(active_counts),
          on: fragment("? = ?::text", active.runner_id, runner.id),
          order_by: [asc: runner.name, asc: runner.id],
          select: {runner, coalesce(active.active_count, 0)}
      )

    {:ok,
     Enum.map(runners, fn {runner, active} ->
       concurrency = normalize_concurrency(runner.capabilities["concurrency"])

       %{
         id: runner.id,
         name: runner.name,
         admin_state: runner.admin_state,
         connectivity: connectivity(runner, active, now),
         labels: runner.labels,
         capabilities: runner.capabilities,
         protocol_version: runner.protocol_version,
         software_version: runner.software_version,
         last_seen_at: runner.last_seen_at,
         active_attempts: active,
         concurrency: concurrency,
         available_slots: max(concurrency - active, 0)
       }
     end)}
  end

  @impl true
  def update_configuration(%Runner{} = configured, audit) do
    Repo.transaction(fn ->
      runner =
        Repo.one(
          from runner in RemoteRunner,
            where: runner.id == ^configured.id and runner.admin_state != :revoked,
            lock: "FOR UPDATE"
        )

      if runner do
        with {:ok, _runner} <-
               runner
               |> Ecto.Changeset.change(
                 name: configured.name,
                 labels: configured.labels,
                 admin_state: configured.admin_state,
                 updated_at: configured.updated_at
               )
               |> Repo.update(),
             {:ok, _event} <-
               audit_event(
                 audit,
                 "runner.configuration_updated",
                 "remote_runner",
                 configured.id,
                 configured.updated_at,
                 %{before: audit.before, after: audit.after}
               ) do
          :ok
        else
          {:error, changeset} -> Repo.rollback({:runner_persistence, changeset})
        end
      else
        Repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  @impl true
  def rotate_credential(runner_id, credential, now, overlap_expires_at, audit) do
    Repo.transaction(fn ->
      runner =
        Repo.one(
          from runner in RemoteRunner,
            where: runner.id == ^runner_id and runner.admin_state != :revoked,
            lock: "FOR UPDATE"
        )

      if runner do
        {_count, _} =
          Repo.update_all(
            from(existing in RunnerCredential,
              where:
                existing.runner_id == ^runner_id and is_nil(existing.revoked_at) and
                  (is_nil(existing.expires_at) or existing.expires_at > ^overlap_expires_at)
            ),
            set: [expires_at: overlap_expires_at]
          )

        with {:ok, _credential} <-
               RunnerCredential.changeset(
                 %RunnerCredential{},
                 Map.put(credential, :runner_id, runner_id)
               )
               |> Repo.insert(),
             {:ok, _event} <-
               audit_event(
                 audit,
                 "runner.credential_rotated",
                 "remote_runner",
                 runner_id,
                 now,
                 %{previous_credentials_expire_at: overlap_expires_at}
               ) do
          :ok
        else
          {:error, changeset} -> Repo.rollback({:runner_persistence, changeset})
        end
      else
        Repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  @impl true
  def revoke(runner_id, revoked_at, audit) do
    Repo.transaction(fn ->
      case Repo.one(
             from runner in RemoteRunner, where: runner.id == ^runner_id, lock: "FOR UPDATE"
           ) do
        nil ->
          Repo.rollback(:not_found)

        runner ->
          with {:ok, _runner} <-
                 runner
                 |> Ecto.Changeset.change(
                   admin_state: :revoked,
                   revoked_at: revoked_at,
                   updated_at: revoked_at
                 )
                 |> Repo.update(),
               {_count, _} <-
                 Repo.update_all(
                   from(credential in RunnerCredential,
                     where: credential.runner_id == ^runner_id and is_nil(credential.revoked_at)
                   ),
                   set: [revoked_at: revoked_at]
                 ),
               {:ok, _event} <-
                 audit_event(
                   audit,
                   "runner.revoked",
                   "remote_runner",
                   runner_id,
                   revoked_at,
                   %{}
                 ) do
            :ok
          else
            {:error, changeset} -> Repo.rollback({:runner_persistence, changeset})
          end
      end
    end)
    |> unwrap_transaction()
  end

  @impl true
  def audit_authentication_failure(runner_id, occurred_at, audit) do
    target_id =
      if match?({:ok, _}, Ecto.UUID.cast(runner_id)), do: runner_id, else: @unknown_runner_id

    case audit_event(
           audit,
           "runner.authentication_failed",
           "remote_runner",
           target_id,
           occurred_at,
           %{claimed_runner_id_valid: target_id != @unknown_runner_id}
         ) do
      {:ok, _event} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  defp audit_event(audit, action, target_type, target_id, occurred_at, metadata) do
    AuditEvent.changeset(%AuditEvent{}, %{
      actor_id: audit.actor_id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      occurred_at: occurred_at,
      metadata: Map.put(metadata, :correlation_id, audit.correlation_id)
    })
    |> Repo.insert()
  end

  defp connectivity(%RemoteRunner{admin_state: :revoked}, _active, _now), do: :offline
  defp connectivity(%RemoteRunner{last_seen_at: nil}, _active, _now), do: :offline

  defp connectivity(%RemoteRunner{last_seen_at: seen}, active, now) do
    if DateTime.compare(seen, DateTime.add(now, -60, :second)) == :lt do
      :stale
    else
      if active > 0, do: :busy, else: :online
    end
  end

  defp normalize_concurrency(value) when is_integer(value) and value in 1..64, do: value
  defp normalize_concurrency(_value), do: 1

  defp domain_runner(schema) do
    %Runner{
      id: schema.id,
      name: schema.name,
      admin_state: schema.admin_state,
      protocol_version: schema.protocol_version,
      software_version: schema.software_version,
      capabilities: schema.capabilities,
      labels: schema.labels,
      last_authenticated_at: schema.last_authenticated_at,
      last_seen_at: schema.last_seen_at,
      revoked_at: schema.revoked_at,
      inserted_at: schema.inserted_at,
      updated_at: schema.updated_at
    }
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
