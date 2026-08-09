defmodule Robine.Repo.Migrations.CreateAutoscalingPoliciesAndIntents do
  use Ecto.Migration

  def change do
    create table(:autoscaling_policies, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :provider, :string, null: false
      add :runner_template, :map, null: false, default: %{}
      add :labels, {:array, :string}, null: false, default: []
      add :min_runners, :integer, null: false, default: 0
      add :max_runners, :integer, null: false
      add :concurrency, :integer, null: false, default: 1
      add :idle_timeout_seconds, :integer, null: false
      add :scale_up_cooldown_seconds, :integer, null: false
      add :scale_down_cooldown_seconds, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autoscaling_policies, [:name])

    create table(:autoscaling_intents, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :policy_id, references(:autoscaling_policies, type: :uuid, on_delete: :delete_all),
        null: false

      add :idempotency_key, :string, null: false
      add :action, :string, null: false
      add :target_instance_id, :string
      add :status, :string, null: false
      add :desired_capacity, :integer, null: false
      add :observed_capacity, :integer, null: false
      add :last_error, :string
      add :attempted_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autoscaling_intents, [:idempotency_key])
    create index(:autoscaling_intents, [:policy_id, :status])
  end
end
