defmodule Robine.Observability.MetricsTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Security.AesGcmCipher
  alias Robine.Adapters.Workflow.YamlDecoder
  alias Robine.Runtime.Measurements
  alias RobineWeb.Telemetry

  @required_metrics ~w(
    robine.workflow.validation.count
    robine.queue.depth
    robine.queue.oldest_age
    robine.pipeline.state.count
    robine.job.state.count
    robine.pipeline.duration
    robine.scheduler.dispatch.duration
    robine.runner.attempts.active
    robine.runner.leases.expired
    robine.runner.phase.duration
    robine.runner.logs.bytes
    robine.runner.cleanup.count
    robine.runner.exit.count
    robine.github.webhook.count
    robine.github.webhook.ack.duration
    robine.github.delivery.duration
    robine.github.api.request.count
    robine.identity.login.count
    robine.identity.oidc.failure.count
    robine.identity.session.revocation.count
    robine.identity.rate_limit.count
    robine.identity.authorization.reject.count
    robine.web.liveview.connection.count
    robine.web.page.duration
    robine.web.log_segment.duration
    robine.storage.blob.write.bytes
    robine.storage.cache.request.count
    robine.storage.quota_denial.count
    robine.secrets.decryption_failure.count
    robine.secrets.redaction.match.count
  )

  test "catalogue covers every MVP observability family with bounded labels" do
    metrics = Telemetry.metrics()
    names = MapSet.new(metrics, &metric_name/1)

    assert Enum.all?(@required_metrics, &MapSet.member?(names, &1))

    forbidden_tags = [:repository_id, :repository_name, :commit_sha, :user_id, :email, :error]

    metrics
    |> Enum.filter(&String.starts_with?(metric_name(&1), "robine."))
    |> Enum.each(fn metric ->
      assert Enum.all?(metric.tags, &(&1 not in forbidden_tags)),
             "#{metric_name(metric)} uses an unbounded or sensitive tag"
    end)
  end

  test "periodic, workflow, and secret failure events emit their declared measurements" do
    handler_id = "metrics-contract-#{System.unique_integer([:positive])}"

    events = [
      [:robine, :queue],
      [:robine, :pipeline, :state],
      [:robine, :job, :state],
      [:robine, :runner, :attempts],
      [:robine, :workflow, :validation],
      [:robine, :secrets, :decryption_failure]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, receiver ->
          send(receiver, {:metric_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Measurements.operational_state()
    assert {:ok, _decoded} = YamlDecoder.decode("version: 1\nname: CI\non: {}\njobs: {}\n")
    assert {:error, :invalid_ciphertext} = AesGcmCipher.decrypt(%{}, "aad")

    assert_receive {:metric_event, [:robine, :queue], %{depth: depth, oldest_age: age}, %{}}
    assert is_integer(depth) and depth >= 0
    assert is_integer(age) and age >= 0

    assert_receive {:metric_event, [:robine, :runner, :attempts],
                    %{active: active, queued: queued, expired_leases: expired}, %{}}

    assert Enum.all?([active, queued, expired], &(is_integer(&1) and &1 >= 0))

    assert_receive {:metric_event, [:robine, :workflow, :validation],
                    %{count: 1, duration: duration}, %{outcome: :ok, schema_version: 1}}

    assert is_integer(duration) and duration >= 0

    assert_receive {:metric_event, [:robine, :secrets, :decryption_failure], %{count: 1},
                    %{reason: :invalid_ciphertext}}
  end

  defp metric_name(metric), do: Enum.join(metric.name, ".")
end
