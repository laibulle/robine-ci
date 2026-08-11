defmodule RobineWeb.PipelineLive.Show do
  use RobineWeb, :live_view
  alias Robine.Pipelines

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 2_000)
    {:ok, socket |> assign(pipeline_id: id) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 2_000)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    case Pipelines.cancel_pipeline(
           %{pipeline_id: socket.assigns.pipeline_id},
           socket.assigns.execution_context
         ) do
      {:ok, _pipeline} ->
        {:noreply, socket |> put_flash(:info, "Cancellation requested.") |> load()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to cancel pipelines.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Pipeline cancellation could not be requested.")}
    end
  end

  defp load(socket) do
    case Pipelines.pipeline_snapshot(
           %{pipeline_id: socket.assigns.pipeline_id},
           socket.assigns.execution_context
         ) do
      {:ok, pipeline} ->
        assign(socket, pipeline: pipeline, load_error: nil)

      {:error, :not_found} ->
        socket |> put_flash(:error, "Pipeline not found.") |> push_navigate(to: ~p"/pipelines")

      {:error, reason} ->
        assign(socket, pipeline: nil, load_error: inspect(reason))
    end
  end

  defp duration(nil), do: "Not started"
  defp duration(milliseconds) when milliseconds < 1_000, do: "#{milliseconds} ms"

  defp duration(milliseconds) do
    seconds = div(milliseconds, 1_000)
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)
    if minutes > 0, do: "#{minutes}m #{remaining_seconds}s", else: "#{seconds}s"
  end

  defp label(nil), do: "Waiting"
  defp label(value), do: value |> to_string() |> String.replace("_", " ")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:pipelines}>
      <section :if={@pipeline} class="space-y-8">
        <.page_header
          title={@pipeline.workflow_name}
          eyebrow="Pipeline execution"
          description={@pipeline.commit_sha}
          breadcrumbs={[
            %{label: "Pipelines", navigate: ~p"/pipelines"},
            %{label: @pipeline.workflow_name}
          ]}
        >
          <:meta><.status_badge status={@pipeline.status} size="lg" /></:meta>
          <:actions>
            <.link
              id="workflow-revision-link"
              navigate={~p"/pipelines/#{@pipeline.id}/workflow"}
              class="link mt-3 inline-block text-sm"
            >View immutable workflow revision</.link>
            <button
              :if={
                @current_actor.role in [:administrator, :maintainer] and
                  @pipeline.status in [:created, :queued, :running]
              }
              phx-click="cancel"
              data-confirm="Cancel this pipeline? Running work will stop at the next cancellation boundary."
              class="btn btn-error btn-outline btn-sm border-l-error"
            >Cancel pipeline</button>
          </:actions>
        </.page_header>
        <p
          :if={@pipeline.scheduled_for}
          id="scheduled-for"
          class="mt-3 text-sm text-base-content/65"
        >
          Intended schedule:
          <time datetime={DateTime.to_iso8601(@pipeline.scheduled_for)}>{DateTime.to_iso8601(
            @pipeline.scheduled_for
          )}</time>
        </p>
        <div
          :if={map_size(@pipeline.inputs) > 0}
          id="manual-inputs"
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <p class="font-semibold">Manual inputs</p>
          <p class="mt-1 text-xs text-base-content/55">These values are non-secret and retained.</p>
          <dl class="mt-3 grid gap-2 sm:grid-cols-2">
            <div
              :for={{name, value} <- Enum.sort(@pipeline.inputs)}
              class="rounded-xl bg-base-200 p-3"
            >
              <dt class="font-mono text-xs text-base-content/55">{name}</dt>
              <dd class="mt-1 break-all font-mono text-sm">{value}</dd>
            </div>
          </dl>
        </div>
        <div
          :if={Enum.any?(@pipeline.jobs, & &1.infrastructure_failure)}
          class="alert alert-error"
          role="alert"
        >
          <div>
            <p class="font-semibold">Infrastructure failure</p>
            <p class="text-sm">
              A runner or Robine service failed independently of the repository command. Retry after checking instance health.
            </p>
          </div>
        </div>
        <dl class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div class="stat rounded-2xl border border-base-300">
            <dt class="stat-title">Trigger</dt><dd class="stat-value text-lg capitalize">
              {label(@pipeline.trigger)}
            </dd>
          </div><div class="stat rounded-2xl border border-base-300">
            <dt class="stat-title">Actor</dt><dd class="stat-value truncate text-lg">
              {@pipeline.actor}
            </dd>
          </div><div class="stat rounded-2xl border border-base-300">
            <dt class="stat-title">Duration</dt><dd class="stat-value text-lg">
              {duration(@pipeline.duration_ms)}
            </dd>
          </div><div class="stat rounded-2xl border border-base-300">
            <dt class="stat-title">Jobs</dt><dd class="stat-value text-lg">
              {length(@pipeline.jobs)}
            </dd>
          </div>
        </dl>
        <div>
          <h2 class="text-xl font-semibold">Dependency order</h2><ol
            class="mt-4 grid gap-3"
            aria-label="Pipeline jobs"
          >
            <li
              :for={job <- @pipeline.jobs}
              id={"pipeline-job-#{job.id}"}
            >
              <.link
                navigate={~p"/pipelines/#{@pipeline.id}/jobs/#{job.id}"}
                class="group flex items-center justify-between gap-4 rounded-2xl border border-base-300 bg-base-100 p-5 transition duration-200 hover:-translate-y-0.5 hover:border-primary/35 hover:shadow-lg hover:shadow-primary/5 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary"
              >
                <div>
                  <span class="font-semibold group-hover:text-primary">{job.job_key}</span><p class="mt-1 text-sm text-base-content/60">
                    {if job.needs == [],
                      do: "No dependencies",
                      else: "Needs: #{Enum.join(job.needs, ", ")}"}
                  </p>
                  <div :if={map_size(job.matrix_values) > 0} class="mt-2 flex flex-wrap gap-1.5">
                    <span
                      :for={{axis, value} <- Enum.sort(job.matrix_values)}
                      class="badge badge-outline badge-sm font-mono"
                    >{axis}={value}</span>
                  </div>
                </div><div class="text-right">
                  <.status_badge status={job.status} />
                  <p class="mt-2 text-xs capitalize text-base-content/60">
                    Phase: {label(job.phase)} · {duration(job.duration_ms)}
                  </p>
                  <p
                    :if={job.result_reason}
                    class={[
                      "mt-1 text-xs capitalize",
                      job.infrastructure_failure && "font-semibold text-error"
                    ]}
                  >
                    Reason: {label(job.result_reason)}
                  </p>
                  <span class="mt-3 inline-flex items-center justify-end gap-1.5 text-xs font-semibold text-primary opacity-70 transition group-hover:opacity-100">
                    View logs and details <.icon name="hero-arrow-right" class="size-3.5" />
                  </span>
                </div>
              </.link>
            </li>
          </ol>
        </div>
      </section>
      <.ui_state :if={@load_error} kind={:error} title="Pipeline state is temporarily unavailable">
        Retrying automatically. The runner is not interrupted by this display error.
      </.ui_state>
    </Layouts.app>
    """
  end
end
