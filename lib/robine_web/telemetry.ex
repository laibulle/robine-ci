defmodule RobineWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics, except: [distribution: 2]

  @duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 15_000, 30_000]
  @byte_buckets [1_024, 4_096, 16_384, 65_536, 262_144, 1_048_576, 4_194_304, 16_777_216]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core,
       metrics: metrics(), name: :robine_prometheus, start_async: false},
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      last_value("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      distribution("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      distribution("robine.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      distribution("robine.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      distribution("robine.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      distribution("robine.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      distribution("robine.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      counter("robine.outbox.delivery.count", tags: [:outcome]),
      sum("robine.outbox.reconciliation.count"),
      sum("robine.secrets.rotation.count", tags: [:from_version, :to_version]),
      sum("robine.storage.blob.write.bytes", tags: [:outcome]),
      counter("robine.storage.blob.write.count", tags: [:outcome]),
      last_value("robine.storage.reconciliation.logical_bytes"),
      last_value("robine.storage.reconciliation.physical_bytes"),
      sum("robine.storage.reconciliation.orphan_objects"),
      sum("robine.storage.reconciliation.missing_objects"),
      sum("robine.storage.reconciliation.unsafe_objects"),
      sum("robine.storage.reconciliation.temporary_deleted"),
      last_value("robine.storage.pressure.available_bytes", tags: [:status]),
      last_value("robine.storage.pressure.used_percent", tags: [:status]),
      counter("robine.github.api.request.count", tags: [:method, :outcome, :status]),
      distribution("robine.github.api.request.duration",
        tags: [:method, :outcome, :status],
        unit: {:native, :millisecond}
      ),
      last_value("robine.github.api.request.rate_limit_remaining"),
      last_value("robine.github.api.request.rate_limit_limit"),
      last_value("robine.github.api.request.rate_limit_reset"),
      counter("robine.source_control.request.count",
        tags: [:provider, :operation, :outcome, :status]
      ),
      distribution("robine.source_control.request.duration",
        tags: [:provider, :operation, :outcome, :status],
        unit: {:native, :millisecond}
      ),
      counter("robine.source_control.webhook.count", tags: [:provider, :outcome, :event]),
      distribution("robine.source_control.webhook.duration",
        tags: [:provider, :outcome, :event],
        unit: {:native, :millisecond}
      ),
      counter("robine.source_control.projection.count", tags: [:operation, :outcome]),
      distribution("robine.source_control.delivery.duration",
        tags: [:provider, :outcome],
        unit: {:native, :millisecond}
      ),

      # Workflow validation
      counter("robine.workflow.validation.count", tags: [:outcome, :schema_version]),
      distribution("robine.workflow.validation.duration",
        tags: [:outcome, :schema_version],
        unit: {:native, :millisecond}
      ),
      last_value("robine.workflow.expansion.expanded_jobs"),
      last_value("robine.workflow.expansion.matrix_variants"),
      counter("robine.workflow.composition.count", tags: [:outcome]),
      distribution("robine.workflow.composition.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      last_value("robine.workflow.composition.source_files", tags: [:outcome]),
      last_value("robine.workflow.composition.max_depth", tags: [:outcome]),
      last_value("robine.workflow.composition.composed_jobs", tags: [:outcome]),
      distribution("robine.workflow.manual.duration",
        tags: [:operation, :outcome],
        unit: {:native, :millisecond}
      ),
      sum("robine.workflow.manual.input_count", tags: [:operation, :outcome]),
      sum("robine.workflow.manual.workflow_count", tags: [:operation, :outcome]),
      distribution("robine.workflow.schedule.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      sum("robine.workflow.schedule.scanned_minutes", tags: [:outcome]),
      sum("robine.workflow.schedule.due_occurrences", tags: [:outcome]),
      sum("robine.workflow.schedule.pipelines", tags: [:outcome]),
      sum("robine.workflow.schedule.truncated_minutes", tags: [:outcome]),

      # Durable scheduling and pipeline state
      last_value("robine.queue.depth"),
      last_value("robine.queue.oldest_age", unit: :second),
      last_value("robine.pipeline.state.count", tags: [:status]),
      last_value("robine.job.state.count", tags: [:status]),
      counter("robine.pipeline.transition.count", tags: [:entity, :outcome]),
      distribution("robine.pipeline.duration", tags: [:outcome], unit: :millisecond),
      counter("robine.pipeline.retry.count", tags: [:outcome]),
      counter("robine.condition.evaluation.count", tags: [:scope, :condition, :outcome]),
      distribution("robine.scheduler.dispatch.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),

      # Local runner
      last_value("robine.runner.attempts.active"),
      last_value("robine.runner.attempts.queued"),
      last_value("robine.runner.leases.expired"),
      distribution("robine.runner.phase.duration", tags: [:phase, :outcome], unit: :millisecond),
      distribution("robine.runner.image_pull.duration", tags: [:outcome], unit: :millisecond),
      sum("robine.runner.logs.bytes", tags: [:phase]),
      distribution("robine.runner.cancellation.duration", tags: [:outcome], unit: :millisecond),
      counter("robine.runner.cleanup.count", tags: [:outcome]),
      last_value("robine.runner.orphans.containers"),
      last_value("robine.runner.orphans.volumes"),
      counter("robine.runner.exit.count", tags: [:reason]),

      # GitHub ingress and projections
      counter("robine.github.webhook.count", tags: [:outcome, :event]),
      distribution("robine.github.webhook.ack.duration",
        tags: [:outcome, :event],
        unit: {:native, :millisecond}
      ),
      distribution("robine.github.delivery.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      counter("robine.github.check.reconciliation.count", tags: [:outcome]),

      # Authentication and authorization
      counter("robine.identity.login.count", tags: [:method, :outcome]),
      counter("robine.identity.oidc.failure.count", tags: [:phase]),
      counter("robine.identity.session.revocation.count", tags: [:outcome]),
      counter("robine.identity.rate_limit.count", tags: [:method]),
      counter("robine.identity.authorization.reject.count", tags: [:role, :surface]),

      # Web experience
      counter("robine.web.liveview.connection.count", tags: [:outcome]),
      distribution("robine.web.page.duration",
        tags: [:page, :outcome],
        unit: {:native, :millisecond}
      ),
      distribution("robine.web.log_segment.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      distribution("robine.web.payload.bytes", tags: [:page], unit: :byte),
      counter("robine.web.action.failure.count", tags: [:action]),

      # Complete storage and secret catalogue
      counter("robine.storage.cache.request.count", tags: [:outcome]),
      distribution("robine.storage.request.duration",
        tags: [:operation, :outcome],
        unit: {:native, :millisecond}
      ),
      counter("robine.storage.quota_denial.count", tags: [:scope]),
      counter("robine.storage.eviction.count", tags: [:kind, :outcome]),
      counter("robine.storage.corruption.count", tags: [:kind]),
      counter("robine.storage.retry.count", tags: [:operation, :outcome]),
      counter("robine.secrets.decryption_failure.count", tags: [:reason]),
      counter("robine.secrets.missing_reference.count"),
      sum("robine.secrets.redaction.match.count"),
      last_value("robine.secrets.rotation.remaining")
    ]
  end

  defp periodic_measurements do
    [
      {Robine.Runtime.Measurements, :storage_pressure, []},
      {Robine.Runtime.Measurements, :operational_state, []}
    ]
  end

  defp distribution(name, options) do
    buckets = if String.ends_with?(name, ".bytes"), do: @byte_buckets, else: @duration_buckets

    Telemetry.Metrics.distribution(
      name,
      Keyword.put(options, :reporter_options, buckets: buckets)
    )
  end
end
