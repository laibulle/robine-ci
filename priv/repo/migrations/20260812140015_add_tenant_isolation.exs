defmodule Robine.Repo.Migrations.AddTenantIsolation do
  use Ecto.Migration

  @tables ~w(
    artifacts audit_events autoscaling_intents autoscaling_policies cache_entries
    github_checks github_deliveries github_repositories job_attempts log_chunks outbox_events
    pipeline_jobs pipelines remote_runners runner_attempt_events runner_credentials
    runner_enrollment_tokens schedule_reconciliation_states secrets storage_backend_states
    storage_gc_candidates attempt_steps workflow_revisions
  )

  @tenant_expression "COALESCE(NULLIF(current_setting('robine.tenant_id', true), ''), 'standalone')"

  def up do
    create table(:ci_tenants, primary_key: false) do
      add :id, :text, primary_key: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:ci_tenants, [:inserted_at])

    Enum.each(@tables, fn table ->
      qualified_table = qualified(table)

      alter table(String.to_atom(table)) do
        add :tenant_id, :text, null: false, default: "standalone"
      end

      execute(
        "ALTER TABLE #{qualified_table} ALTER COLUMN tenant_id SET DEFAULT #{@tenant_expression}"
      )

      execute("ALTER TABLE #{qualified_table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{qualified_table} FORCE ROW LEVEL SECURITY")

      execute(
        "CREATE POLICY #{table}_tenant_isolation ON #{qualified_table} " <>
          "USING (tenant_id = #{@tenant_expression}) " <>
          "WITH CHECK (tenant_id = #{@tenant_expression})"
      )

      create index(String.to_atom(table), [:tenant_id])
    end)

    scope_unique_indexes()
    scope_fixed_primary_keys()
  end

  def down do
    restore_fixed_primary_keys()
    restore_unique_indexes()

    Enum.each(Enum.reverse(@tables), fn table ->
      qualified_table = qualified(table)
      execute("DROP POLICY IF EXISTS #{table}_tenant_isolation ON #{qualified_table}")
      execute("ALTER TABLE #{qualified_table} DISABLE ROW LEVEL SECURITY")

      alter table(String.to_atom(table)) do
        remove :tenant_id
      end
    end)

    drop table(:ci_tenants)
  end

  defp scope_unique_indexes do
    indexes = [
      {:artifacts, [:attempt_id, :name], :artifacts_attempt_id_name_index},
      {:cache_entries, [:repository_id, :key], :cache_entries_repository_id_key_index},
      {:log_chunks, [:attempt_id, :sequence], :log_chunks_attempt_id_sequence_index},
      {:autoscaling_policies, [:name], :autoscaling_policies_name_index},
      {:autoscaling_intents, [:idempotency_key], :autoscaling_intents_idempotency_key_index},
      {:pipeline_jobs, [:pipeline_id, :job_key], :pipeline_jobs_pipeline_id_job_key_index},
      {:job_attempts, [:job_id, :number], :job_attempts_job_id_number_index},
      {:job_attempts, [:idempotency_token], :job_attempts_idempotency_token_index},
      {:attempt_steps, [:attempt_id, :position], :attempt_steps_attempt_id_position_index},
      {:workflow_revisions, [:pipeline_id], :workflow_revisions_pipeline_id_index},
      {:runner_attempt_events, [:runner_id, :message_id],
       :runner_attempt_events_runner_id_message_id_index},
      {:runner_attempt_events, [:attempt_id, :sequence],
       :runner_attempt_events_attempt_id_sequence_index},
      {:runner_enrollment_tokens, [:token_digest], :runner_enrollment_tokens_token_digest_index},
      {:runner_credentials, [:credential_digest], :runner_credentials_credential_digest_index}
    ]

    Enum.each(indexes, fn {table, fields, name} ->
      drop_if_exists(index(table, fields, name: name))
      create(unique_index(table, [:tenant_id | fields], name: name))
    end)

    replace_named_unique_index(
      :secrets,
      [:scope, :repository_id, :name],
      :secrets_scope_repository_name_index,
      nulls_distinct: false
    )

    replace_named_unique_index(
      :github_repositories,
      [:provider, :provider_instance, :provider_id],
      :source_control_repositories_provider_identity_index
    )

    replace_named_unique_index(
      :github_repositories,
      [:provider, :provider_instance, :full_name],
      :source_control_repositories_provider_name_index
    )

    replace_named_unique_index(
      :github_deliveries,
      [:provider, :provider_instance, :provider_delivery_id],
      :source_control_deliveries_provider_identity_index
    )

    replace_named_unique_index(
      :github_checks,
      [:provider, :provider_instance, :external_key],
      :source_control_statuses_provider_external_key_index
    )
  end

  defp replace_named_unique_index(table, fields, name, options \\ []) do
    drop_if_exists(index(table, fields, name: name))
    create(unique_index(table, [:tenant_id | fields], Keyword.put(options, :name, name)))
  end

  defp scope_fixed_primary_keys do
    Enum.each(
      [
        {:schedule_reconciliation_states, :key},
        {:storage_backend_states, :id},
        {:storage_gc_candidates, :blob_id}
      ],
      fn {table, primary_key} ->
        table_name = Atom.to_string(table)
        qualified_table = qualified(table_name)

        execute("ALTER TABLE #{qualified_table} DROP CONSTRAINT #{table_name}_pkey")
        execute("ALTER TABLE #{qualified_table} ADD PRIMARY KEY (tenant_id, #{primary_key})")
      end
    )
  end

  defp restore_unique_indexes do
    indexes = [
      {:artifacts, [:attempt_id, :name], :artifacts_attempt_id_name_index},
      {:cache_entries, [:repository_id, :key], :cache_entries_repository_id_key_index},
      {:log_chunks, [:attempt_id, :sequence], :log_chunks_attempt_id_sequence_index},
      {:autoscaling_policies, [:name], :autoscaling_policies_name_index},
      {:autoscaling_intents, [:idempotency_key], :autoscaling_intents_idempotency_key_index},
      {:pipeline_jobs, [:pipeline_id, :job_key], :pipeline_jobs_pipeline_id_job_key_index},
      {:job_attempts, [:job_id, :number], :job_attempts_job_id_number_index},
      {:job_attempts, [:idempotency_token], :job_attempts_idempotency_token_index},
      {:attempt_steps, [:attempt_id, :position], :attempt_steps_attempt_id_position_index},
      {:workflow_revisions, [:pipeline_id], :workflow_revisions_pipeline_id_index},
      {:runner_attempt_events, [:runner_id, :message_id],
       :runner_attempt_events_runner_id_message_id_index},
      {:runner_attempt_events, [:attempt_id, :sequence],
       :runner_attempt_events_attempt_id_sequence_index},
      {:runner_enrollment_tokens, [:token_digest], :runner_enrollment_tokens_token_digest_index},
      {:runner_credentials, [:credential_digest], :runner_credentials_credential_digest_index},
      {:github_repositories, [:provider, :provider_instance, :provider_id],
       :source_control_repositories_provider_identity_index},
      {:github_repositories, [:provider, :provider_instance, :full_name],
       :source_control_repositories_provider_name_index},
      {:github_deliveries, [:provider, :provider_instance, :provider_delivery_id],
       :source_control_deliveries_provider_identity_index},
      {:github_checks, [:provider, :provider_instance, :external_key],
       :source_control_statuses_provider_external_key_index}
    ]

    Enum.each(indexes, fn {table, fields, name} ->
      drop_if_exists(index(table, [:tenant_id | fields], name: name))
      create(unique_index(table, fields, name: name))
    end)

    drop_if_exists(
      index(:secrets, [:tenant_id, :scope, :repository_id, :name],
        name: :secrets_scope_repository_name_index
      )
    )

    create(
      unique_index(:secrets, [:scope, :repository_id, :name],
        name: :secrets_scope_repository_name_index,
        nulls_distinct: false
      )
    )
  end

  defp restore_fixed_primary_keys do
    Enum.each(
      [
        {:schedule_reconciliation_states, :key},
        {:storage_backend_states, :id},
        {:storage_gc_candidates, :blob_id}
      ],
      fn {table, primary_key} ->
        table_name = Atom.to_string(table)
        qualified_table = qualified(table_name)

        execute("ALTER TABLE #{qualified_table} DROP CONSTRAINT #{table_name}_pkey")
        execute("ALTER TABLE #{qualified_table} ADD PRIMARY KEY (#{primary_key})")
      end
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> ~s("#{table}")
      database_prefix -> ~s("#{database_prefix}"."#{table}")
    end
  end
end
