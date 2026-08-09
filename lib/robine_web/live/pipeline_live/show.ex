defmodule RobineWeb.PipelineLive.Show do
  use RobineWeb, :live_view
  alias Robine.Pipelines
  alias Robine.Adapters.Background.SyncGitHubChecksWorker

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
        _ =
          %{pipeline_id: socket.assigns.pipeline_id}
          |> SyncGitHubChecksWorker.new()
          |> Oban.insert()

        {:noreply, socket |> put_flash(:info, "Cancellation requested.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot cancel pipeline: #{inspect(reason)}")}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section :if={@pipeline} class="space-y-8">
        <header>
          <.link navigate={~p"/pipelines"} class="link text-sm">← All pipelines</.link><div class="mt-4 flex flex-wrap items-center gap-3">
            <h1 class="text-4xl font-bold">{@pipeline.workflow_name}</h1><span class="badge badge-lg">{@pipeline.status}</span>
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
        </header>
        <div class="grid gap-4 md:grid-cols-3">
          <div class="stat rounded-2xl border border-base-300">
            <div class="stat-title">Jobs</div><div class="stat-value">{length(@pipeline.jobs)}</div>
          </div><div class="stat rounded-2xl border border-base-300">
            <div class="stat-title">Started</div><div class="stat-value text-lg">
              {Calendar.strftime(@pipeline.inserted_at, "%H:%M UTC")}
            </div>
          </div><div class="stat rounded-2xl border border-base-300">
            <div class="stat-title">Reproduce</div><div class="stat-desc">
              <code>robine run</code>
            </div>
          </div>
        </div>
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
                </div><span class="badge">{job.status}</span>
              </div>
            </li>
          </ol>
        </div>
      </section>
      <div :if={@load_error} class="alert alert-error" role="alert">
        Pipeline state is temporarily unavailable. Retrying automatically.
      </div>
    </Layouts.app>
    """
  end
end
