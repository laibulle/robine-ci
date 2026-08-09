defmodule RobineWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
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
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("robine.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("robine.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("robine.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("robine.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("robine.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),
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
      summary("robine.github.api.request.duration",
        tags: [:method, :outcome, :status],
        unit: {:native, :millisecond}
      ),
      last_value("robine.github.api.request.rate_limit_remaining"),
      last_value("robine.github.api.request.rate_limit_limit"),
      last_value("robine.github.api.request.rate_limit_reset")
    ]
  end

  defp periodic_measurements do
    [
      {Robine.Runtime.Measurements, :storage_pressure, []}
    ]
  end
end
