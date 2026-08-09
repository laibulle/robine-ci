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
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section :if={@pipeline} class="space-y-8">
        <header>
          <.link navigate={~p"/pipelines"} class="link text-sm">← All pipelines</.link><div class="mt-4 flex flex-wrap items-center gap-3">
            <h1 class="text-4xl font-bold">{@pipeline.workflow_name}</h1><.status_badge
              status={@pipeline.status}
              size="lg"
            />
            <button
              :if={
                @current_actor.role in [:administrator, :maintainer] and
                  @pipeline.status in [:created, :queued, :running]
              }
              phx-click="cancel"
              data-confirm="Cancel this pipeline? Running work will stop at the next cancellation boundary."
              class="btn btn-error btn-sm"
            >Cancel pipeline</button>
          </div><p class="mt-3 font-mono text-sm text-base-content/65">{@pipeline.commit_sha}</p>
          <.link
            id="workflow-revision-link"
            navigate={~p"/pipelines/#{@pipeline.id}/workflow"}
            class="link mt-3 inline-block text-sm"
          >View immutable workflow revision</.link>
        </header>
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
              class="rounded-2xl border border-base-300 bg-base-100 p-5"
            >
              <div class="flex items-center justify-between gap-4">
                <div>
                  <.link
                    navigate={~p"/pipelines/#{@pipeline.id}/jobs/#{job.id}"}
                    class="font-semibold link link-hover"
                  >{job.job_key}</.link><p class="mt-1 text-sm text-base-content/60">
                    {if job.needs == [],
                      do: "No dependencies",
                      else: "Needs: #{Enum.join(job.needs, ", ")}"}
                  </p>
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
                </div>
              </div>
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
