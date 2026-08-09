defmodule RobineWeb.JobLive.Show do
  use RobineWeb, :live_view
  alias Robine.{Pipelines, Runners}
  @log_window 50

  @impl true
  def mount(%{"id" => pipeline_id, "job_id" => job_id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_logs, 1_000)

    {:ok,
     socket
     |> assign(
       pipeline_id: pipeline_id,
       job_id: job_id,
       log_chunks: [],
       log_cursor: 0,
       attempt_id: nil,
       query: ""
     )
     |> load()}
  end

  @impl true
  def handle_info(:refresh_logs, socket) do
    Process.send_after(self(), :refresh_logs, 1_000)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("filter", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: query)}

  def handle_event("retry", _params, socket) do
    case Pipelines.retry_job(%{job_id: socket.assigns.job_id}, socket.assigns.execution_context) do
      {:ok, _result} ->
        {:noreply, socket |> put_flash(:info, "Job queued for retry.") |> load()}

      {:error, {:retry_dependencies_unavailable, dependencies}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Retry requires successful dependencies: #{Enum.join(dependencies, ", ")}."
         )}

      {:error, {:retry_inputs_unavailable, %{inputs: inputs, rerun_jobs: jobs}}} ->
        {:noreply,
         socket
         |> assign(rerun_suggestion: %{inputs: inputs, jobs: jobs})
         |> put_flash(
           :error,
           "Retry refused; unavailable artifacts: #{Enum.join(inputs, ", ")}."
         )}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to retry jobs.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The job could not be retried.")}
    end
  end

  def handle_event("rerun-dependencies", _params, socket) do
    case Pipelines.retry_job(
           %{job_id: socket.assigns.job_id, rerun_dependencies: true},
           socket.assigns.execution_context
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(rerun_suggestion: nil)
         |> put_flash(
           :info,
           "Queued #{Enum.join(result.rerun_jobs, ", ")} before retrying this job."
         )
         |> load()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to retry jobs.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The dependency jobs could not be rerun.")}
    end
  end

  defp load(socket) do
    case Pipelines.job_detail(%{job_id: socket.assigns.job_id}, socket.assigns.execution_context) do
      {:ok, detail} ->
        placement = placement(detail.job, socket.assigns.execution_context)

        socket
        |> assign(
          pipeline: detail.pipeline,
          job: detail.job,
          attempt: detail.attempt,
          placement: placement,
          rerun_suggestion: Map.get(socket.assigns, :rerun_suggestion)
        )
        |> load_new_logs()

      _error ->
        socket |> put_flash(:error, "Job not found.") |> push_navigate(to: ~p"/pipelines")
    end
  end

  defp placement(%{status: :queued, runs_on: labels}, context) do
    case Runners.explain_capacity(%{labels: labels}, context) do
      {:ok, explanation} -> explanation
      {:error, _reason} -> nil
    end
  end

  defp placement(_job, _context), do: nil

  defp placement_message(:absent), do: "No registered runner satisfies every requested label."
  defp placement_message(:offline), do: "Matching runners exist, but they are offline or stale."
  defp placement_message(:draining), do: "Matching runners are draining and accept no new work."
  defp placement_message(:busy), do: "Every matching runner is currently at capacity."
  defp placement_message(:available), do: "Compatible capacity is available; dispatch is pending."

  defp load_new_logs(socket) do
    started = System.monotonic_time()
    current_attempt_id = socket.assigns.attempt && socket.assigns.attempt.id

    socket =
      if current_attempt_id != socket.assigns.attempt_id,
        do: assign(socket, attempt_id: current_attempt_id, log_chunks: [], log_cursor: 0),
        else: socket

    case Pipelines.list_job_logs(
           %{job_id: socket.assigns.job_id, after: socket.assigns.log_cursor, limit: @log_window},
           socket.assigns.execution_context
         ) do
      {:ok, page} ->
        :telemetry.execute(
          [:robine, :web, :log_segment],
          %{duration: System.monotonic_time() - started},
          %{outcome: :ok}
        )

        :telemetry.execute(
          [:robine, :web, :payload],
          %{bytes: Enum.reduce(page.chunks, 0, &(byte_size(&1.content) + &2))},
          %{page: :job_logs}
        )

        assign(socket,
          log_chunks: Enum.take(socket.assigns.log_chunks ++ page.chunks, -@log_window),
          log_cursor: page.next_cursor
        )

      {:error, _reason} ->
        :telemetry.execute(
          [:robine, :web, :log_segment],
          %{duration: System.monotonic_time() - started},
          %{outcome: :error}
        )

        socket
    end
  end

  defp visible_phases(chunks, query) do
    chunks
    |> Enum.chunk_by(& &1.phase)
    |> Enum.map(fn phase_chunks ->
      phase = hd(phase_chunks).phase

      %{
        key: phase,
        label: phase_label(phase),
        groups: phase_chunks |> step_groups(phase) |> filter_groups(query)
      }
    end)
    |> Enum.reject(&(&1.groups == []))
  end

  defp step_groups(chunks, phase) do
    chunks
    |> Enum.chunk_by(& &1.step_position)
    |> Enum.map(fn step_chunks ->
      first = hd(step_chunks)
      last = List.last(step_chunks)

      %{
        id:
          if(phase == "execution",
            do: "step-#{first.step_position}",
            else: "phase-#{phase}-step-#{first.step_position}"
          ),
        position: first.step_position,
        name: first.step_name,
        status: last.step_status,
        duration_ms: last.duration_ms,
        chunks: step_chunks
      }
    end)
  end

  defp filter_groups(groups, ""), do: groups

  defp filter_groups(groups, query) do
    normalized = String.downcase(query)

    Enum.filter(groups, fn group ->
      content = Enum.map_join(group.chunks, & &1.content)
      String.contains?(String.downcase(group.name <> "\n" <> content), normalized)
    end)
  end

  defp phase_label("image_acquisition"), do: "Image acquisition"
  defp phase_label("service_preparation"), do: "Service preparation"
  defp phase_label("execution"), do: "Execution"
  defp phase_label("cleanup"), do: "Cleanup"
  defp phase_label(phase), do: phase |> to_string() |> String.replace("_", " ")

  defp stream_label("stdout"), do: "standard output"
  defp stream_label("stderr"), do: "standard error"
  defp stream_label("system"), do: "runner event"
  defp stream_label(_stream), do: "combined output"

  defp local_job_selector(%{matrix_values: values, job_key: key}) when map_size(values) > 0,
    do: "'#{key}'"

  defp local_job_selector(job), do: job.job_key

  defp local_input_flags(inputs) do
    inputs
    |> Enum.sort()
    |> Enum.map_join("", fn {name, value} -> " --input " <> shell_quote("#{name}=#{value}") end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <.link navigate={~p"/pipelines/#{@pipeline.id}"} class="link text-sm">← {@pipeline.workflow_name}</.link>
          <div class="mt-4 flex items-center gap-3">
            <h1 class="text-4xl font-bold">{@job.job_key}</h1><.status_badge
              status={@job.status}
              size="lg"
            />
            <button
              :if={
                @current_actor.role in [:administrator, :maintainer] and
                  @job.status in [:failed, :cancelled]
              }
              phx-click="retry"
              data-confirm="Retry this job using its retained dependency inputs?"
              class="btn btn-primary btn-sm"
            >Retry job</button>
          </div>
          <div
            :if={map_size(@job.matrix_values) > 0}
            id="matrix-values"
            class="mt-3 flex flex-wrap gap-2"
          >
            <span
              :for={{axis, value} <- Enum.sort(@job.matrix_values)}
              class="badge badge-outline font-mono"
            >{axis}={value}</span>
          </div>
        </header>
        <div
          :if={map_size(@pipeline.inputs) > 0}
          id="manual-inputs"
          class="rounded-2xl border border-base-300 bg-base-100 p-4"
        >
          <p class="font-semibold">Manual inputs</p>
          <div class="mt-2 flex flex-wrap gap-2">
            <span
              :for={{name, value} <- Enum.sort(@pipeline.inputs)}
              class="badge badge-outline font-mono"
            >{name}={value}</span>
          </div>
        </div>
        <div
          :if={@job.status == :skipped}
          id="condition-explanation"
          class="rounded-2xl border border-base-300 bg-base-200/60 p-4"
        >
          <p class="font-semibold">Condition did not match</p>
          <p class="mt-1 text-sm text-base-content/65">
            This job was skipped because <code>if: {@job.condition}</code>
            did not match the terminal outcomes of its dependencies.
          </p>
        </div>
        <div
          :if={@placement}
          id="placement-explanation"
          class="rounded-2xl border border-primary/25 bg-primary/5 p-4"
        >
          <p class="font-semibold">Waiting for compatible capacity</p>
          <p class="mt-1 text-sm text-base-content/65">{placement_message(@placement.status)}</p>
          <p class="mt-2 text-xs text-base-content/50">
            Required labels: {Enum.join(@placement.requested_labels, ", ")}
          </p>
        </div>
        <div :if={@rerun_suggestion} class="alert alert-warning">
          <div>
            <p class="font-semibold">Required artifacts expired or are unavailable.</p>
            <p class="text-sm">
              Rerun {Enum.join(@rerun_suggestion.jobs, ", ")} to recreate {Enum.join(
                @rerun_suggestion.inputs,
                ", "
              )}.
            </p>
          </div>
          <button
            phx-click="rerun-dependencies"
            data-confirm="Rerun the smallest producer subgraph?"
            class="btn btn-sm"
          >
            Rerun dependencies
          </button>
        </div>
        <div class="rounded-3xl border border-base-300 bg-neutral p-6 text-neutral-content">
          <div class="flex items-center justify-between">
            <h2 class="font-semibold">Local reproduction</h2><span class="badge badge-outline">Docker</span>
          </div>
          <pre class="mt-4 overflow-x-auto"><code>robine run {local_job_selector(@job)} --workflow .robine-ci/workflows/ci.yml{local_input_flags(@pipeline.inputs)}</code></pre>
          <p class="mt-4 text-sm opacity-70">
            CI-only inputs omitted: GitHub event payload, server-side secrets, and remote caches.
          </p>
        </div>
        <div
          :if={@log_chunks == []}
          class="rounded-3xl border border-dashed border-base-300 p-10 text-center"
        >
          <h2 class="text-xl font-semibold">No retained log segments yet</h2><p class="mt-2 text-base-content/60">
            Logs will appear here by phase and step as the runner persists them.
          </p>
        </div>
        <section :if={@log_chunks != []} class="space-y-4" aria-label="Job logs">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-xl font-semibold">Logs</h2><p class="text-sm text-base-content/60">
                Showing at most 50 recent 64 KB segments.
              </p>
            </div>
            <form id="log-filter-form" phx-change="filter">
              <label class="input input-bordered flex items-center gap-2"><span class="sr-only">Search visible logs</span><.icon
                name="hero-magnifying-glass"
                class="size-4"
              /><input
                type="search"
                name="query"
                value={@query}
                placeholder="Search visible logs"
                phx-debounce="150"
              /></label>
            </form>
          </div>
          <div id="log-segments" class="space-y-6">
            <section
              :for={phase <- visible_phases(@log_chunks, @query)}
              id={"phase-#{phase.key}"}
              aria-labelledby={"phase-#{phase.key}-title"}
              class="space-y-3"
            >
              <h3
                id={"phase-#{phase.key}-title"}
                class="text-sm font-semibold uppercase tracking-wide"
              >
                <a href={"#phase-#{phase.key}"} class="hover:underline">{phase.label}</a>
              </h3>
              <details
                :for={group <- phase.groups}
                id={group.id}
                open
                class="overflow-hidden rounded-2xl border border-base-300 bg-neutral text-neutral-content"
              >
                <summary class="flex cursor-pointer list-none flex-wrap items-center justify-between gap-3 border-b border-neutral-content/15 px-4 py-3">
                  <a href={"##{group.id}"} class="font-semibold hover:underline">{group.name}</a><span class="text-xs opacity-70">{group.status} · {group.duration_ms} ms</span>
                </summary>
                <pre
                  class="max-h-96 overflow-auto whitespace-pre-wrap break-words p-4 text-sm"
                  tabindex="0"
                ><code><span
                    :for={chunk <- group.chunks}
                    id={"log-#{chunk.sequence}"}
                    data-stream={chunk.stream}
                  ><span class="sr-only">{stream_label(chunk.stream)}: </span>{chunk.content}</span></code></pre>
              </details>
            </section>
          </div>
          <p
            :if={@query != "" and visible_phases(@log_chunks, @query) == []}
            class="rounded-2xl border border-dashed border-base-300 p-8 text-center"
          >
            No visible log segment matches “{@query}”.
          </p>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
