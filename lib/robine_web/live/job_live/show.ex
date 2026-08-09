defmodule RobineWeb.JobLive.Show do
  use RobineWeb, :live_view
  alias Robine.Pipelines
  alias Robine.Adapters.Background.{RunNextJobWorker, SyncGitHubChecksWorker}

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
      {:ok, result} ->
        _ = RunNextJobWorker.new(%{}) |> Oban.insert()
        _ = %{pipeline_id: result.pipeline_id} |> SyncGitHubChecksWorker.new() |> Oban.insert()
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot retry job: #{inspect(reason)}")}
    end
  end

  def handle_event("rerun-dependencies", _params, socket) do
    case Pipelines.retry_job(
           %{job_id: socket.assigns.job_id, rerun_dependencies: true},
           socket.assigns.execution_context
         ) do
      {:ok, result} ->
        _ = RunNextJobWorker.new(%{}) |> Oban.insert()
        _ = %{pipeline_id: result.pipeline_id} |> SyncGitHubChecksWorker.new() |> Oban.insert()

        {:noreply,
         socket
         |> assign(rerun_suggestion: nil)
         |> put_flash(
           :info,
           "Queued #{Enum.join(result.rerun_jobs, ", ")} before retrying this job."
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot rerun dependencies: #{inspect(reason)}")}
    end
  end

  defp load(socket) do
    case Pipelines.job_detail(%{job_id: socket.assigns.job_id}, socket.assigns.execution_context) do
      {:ok, detail} ->
        socket
        |> assign(
          pipeline: detail.pipeline,
          job: detail.job,
          attempt: detail.attempt,
          rerun_suggestion: Map.get(socket.assigns, :rerun_suggestion)
        )
        |> load_new_logs()

      _error ->
        socket |> put_flash(:error, "Job not found.") |> push_navigate(to: ~p"/pipelines")
    end
  end

  defp load_new_logs(socket) do
    current_attempt_id = socket.assigns.attempt && socket.assigns.attempt.id

    socket =
      if current_attempt_id != socket.assigns.attempt_id,
        do: assign(socket, attempt_id: current_attempt_id, log_chunks: [], log_cursor: 0),
        else: socket

    case Pipelines.list_job_logs(
           %{job_id: socket.assigns.job_id, after: socket.assigns.log_cursor, limit: 200},
           socket.assigns.execution_context
         ) do
      {:ok, page} ->
        assign(socket,
          log_chunks: Enum.take(socket.assigns.log_chunks ++ page.chunks, -200),
          log_cursor: page.next_cursor
        )

      {:error, _reason} ->
        socket
    end
  end

  defp visible_groups(chunks, query) do
    groups =
      chunks
      |> Enum.chunk_by(& &1.step_position)
      |> Enum.map(fn step_chunks ->
        first = hd(step_chunks)
        last = List.last(step_chunks)

        %{
          position: first.step_position,
          name: first.step_name,
          status: last.step_status,
          duration_ms: last.duration_ms,
          chunks: step_chunks
        }
      end)

    filter_groups(groups, query)
  end

  defp filter_groups(groups, ""), do: groups

  defp filter_groups(groups, query) do
    normalized = String.downcase(query)

    Enum.filter(groups, fn group ->
      content = Enum.map_join(group.chunks, & &1.content)
      String.contains?(String.downcase(group.name <> "\n" <> content), normalized)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <.link navigate={~p"/pipelines/#{@pipeline.id}"} class="link text-sm">← {@pipeline.workflow_name}</.link>
          <div class="mt-4 flex items-center gap-3">
            <h1 class="text-4xl font-bold">{@job.job_key}</h1><span class="badge badge-lg">{@job.status}</span>
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
        </header>
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
          <pre class="mt-4 overflow-x-auto"><code>robine run {@job.job_key} --workflow .robine-ci/workflows/ci.yml</code></pre>
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
                Showing at most 200 recent 64 KB segments.
              </p>
            </div>
            <form phx-change="filter">
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
          <div id="log-segments" class="space-y-3">
            <details
              :for={group <- visible_groups(@log_chunks, @query)}
              id={"step-#{group.position}"}
              open
              class="overflow-hidden rounded-2xl border border-base-300 bg-neutral text-neutral-content"
            >
              <summary class="flex cursor-pointer list-none flex-wrap items-center justify-between gap-3 border-b border-neutral-content/15 px-4 py-3">
                <a href={"#step-#{group.position}"} class="font-semibold hover:underline">{group.name}</a><span class="text-xs opacity-70">{group.status} · {group.duration_ms} ms</span>
              </summary>
              <pre
                class="max-h-96 overflow-auto whitespace-pre-wrap break-words p-4 text-sm"
                tabindex="0"
              ><code><span :for={chunk <- group.chunks} id={"log-#{chunk.sequence}"}>{chunk.content}</span></code></pre>
            </details>
          </div>
          <p
            :if={@query != "" and visible_groups(@log_chunks, @query) == []}
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
