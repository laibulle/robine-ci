defmodule Robine.Autoscaling.ReconciliationTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.AutoscalingRepository
  alias Robine.Adapters.Persistence.Postgres.Schemas.{AutoscalingIntent, AutoscalingPolicy}
  alias Robine.Autoscaling
  alias Robine.Autoscaling.Dependencies
  alias Robine.ExecutionContext
  alias Robine.TestSupport.FakeAutoscalingProvider
  alias Robine.Repo

  setup do
    start_supervised!({FakeAutoscalingProvider, failure: :before_effect})
    :ok
  end

  test "retries one durable intent with the same provider idempotency key after failure" do
    context = context()

    assert {:ok, policy} =
             Autoscaling.create_policy(
               %{
                 name: "elastic-linux",
                 enabled: true,
                 provider: "fake",
                 runner_template: %{"image" => "runner-v1"},
                 labels: ["docker", "linux"],
                 min_runners: 1,
                 max_runners: 3,
                 concurrency: 2,
                 idle_timeout_seconds: 600,
                 scale_up_cooldown_seconds: 0,
                 scale_down_cooldown_seconds: 0
               },
               context
             )

    assert {:error, {:policy_reconciliation_failed, policy_id, :temporary_provider_failure}} =
             Autoscaling.reconcile(%{}, context)

    assert policy_id == policy.id

    assert %AutoscalingIntent{status: :failed, idempotency_key: key} =
             Repo.one!(AutoscalingIntent)

    assert :ok = stop_supervised(FakeAutoscalingProvider)
    start_supervised!({FakeAutoscalingProvider, failure: nil})
    assert {:ok, %{policies: 1, effects: 1}} = Autoscaling.reconcile(%{}, context)

    assert %AutoscalingIntent{status: :completed, idempotency_key: ^key} =
             Repo.one!(AutoscalingIntent)

    assert [{:provision, ^key}] = FakeAutoscalingProvider.state().calls

    assert length(FakeAutoscalingProvider.state().instances) == 1

    assert {:ok, [%{desired: 1, observed: 1, health: :healthy}]} =
             Autoscaling.fleet_capacity(%{}, context)

    assert {:ok, %{policies: 1, effects: 0}} = Autoscaling.reconcile(%{}, context)
    assert Repo.aggregate(AutoscalingIntent, :count) == 1
    assert Repo.get!(AutoscalingPolicy, policy.id).enabled
  end

  test "keeps the production provider disabled when no policy is configured" do
    runtime =
      Robine.Runtime.Dependencies.context(%{id: "admin", role: :administrator}, "disabled")

    assert {:ok, []} = Autoscaling.fleet_capacity(%{}, runtime)
    assert {:ok, %{policies: 0, effects: 0}} = Autoscaling.reconcile(%{}, runtime)
  end

  test "scales down only an idle instance and protects active leases" do
    context = context()
    FakeAutoscalingProvider.set_failure(nil)
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    FakeAutoscalingProvider.set_instances([
      %{id: "busy", state: :ready, active_leases: 1, last_active_at: old},
      %{id: "idle", state: :ready, active_leases: 0, last_active_at: old}
    ])

    assert {:ok, _policy} =
             Autoscaling.create_policy(
               %{
                 name: "scale-down",
                 enabled: true,
                 provider: "fake",
                 runner_template: %{"pool" => "down"},
                 labels: ["docker"],
                 min_runners: 0,
                 max_runners: 3,
                 concurrency: 1,
                 idle_timeout_seconds: 60,
                 scale_up_cooldown_seconds: 0,
                 scale_down_cooldown_seconds: 0
               },
               context
             )

    assert {:ok, %{policies: 1, effects: 1}} = Autoscaling.reconcile(%{}, context)
    assert [%{id: "busy", active_leases: 1}] = FakeAutoscalingProvider.state().instances

    assert [{:terminate, _key, "idle"}] = FakeAutoscalingProvider.state().calls
    assert Repo.one!(AutoscalingIntent).target_instance_id == "idle"
  end

  test "enforces scale-up cooldown and reports degraded provider health" do
    context = context()
    FakeAutoscalingProvider.set_failure(nil)

    assert {:ok, _policy} =
             Autoscaling.create_policy(
               %{
                 name: "cooldown",
                 enabled: true,
                 provider: "fake",
                 runner_template: %{"pool" => "cooldown"},
                 labels: ["docker"],
                 min_runners: 2,
                 max_runners: 4,
                 concurrency: 1,
                 idle_timeout_seconds: 600,
                 scale_up_cooldown_seconds: 300,
                 scale_down_cooldown_seconds: 300
               },
               context
             )

    assert {:ok, %{effects: 1}} = Autoscaling.reconcile(%{}, context)
    assert {:ok, %{effects: 0}} = Autoscaling.reconcile(%{}, context)
    assert length(FakeAutoscalingProvider.state().instances) == 1

    [instance] = FakeAutoscalingProvider.state().instances
    FakeAutoscalingProvider.set_instances([%{instance | state: :degraded}])

    assert {:ok, [%{desired: 2, observed: 1, health: :degraded}]} =
             Autoscaling.fleet_capacity(%{}, context)
  end

  defp context do
    %ExecutionContext{} =
      base =
      Robine.Runtime.Dependencies.context(%{id: "autoscaler", role: :administrator}, "scale")

    autoscaling = %Dependencies{
      repository: AutoscalingRepository,
      provider: FakeAutoscalingProvider,
      clock: Robine.Adapters.System.Clock,
      id_generator: Robine.Adapters.System.IdGenerator
    }

    %ExecutionContext{base | dependencies: Map.put(base.dependencies, :autoscaling, autoscaling)}
  end
end
