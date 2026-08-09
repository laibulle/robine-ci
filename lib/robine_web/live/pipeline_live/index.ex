defmodule RobineWeb.PipelineLive.Index do
  use RobineWeb, :live_view
  alias Robine.Pipelines

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 2_000)
    {:ok, load(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 2_000)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    case Pipelines.list_pipelines(%{limit: 50}, socket.assigns.execution_context) do
      {:ok, pipelines} -> assign(socket, pipelines: pipelines, load_error: nil)
      {:error, reason} -> assign(socket, pipelines: [], load_error: inspect(reason))
    end
  end

  defp status_class(:succeeded), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:running), do: "badge-info"
  defp status_class(_status), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header class="flex items-end justify-between gap-4">
          <div>
            <p class="text-sm font-semibold uppercase tracking-[0.2em] text-primary">Execution</p><h1 class="mt-2 text-4xl font-bold">
              Pipelines
            </h1>
          </div>
          <span class="text-sm text-base-content/60">Signed in as {@current_actor.email}</span>
        </header>
        <div :if={@load_error} class="alert alert-error" role="alert">
          Pipelines are temporarily unavailable. Retrying automatically.
        </div>
        <div
          :if={@pipelines == [] and is_nil(@load_error)}
          class="rounded-3xl border border-dashed border-base-300 p-12 text-center"
        >
          <h2 class="text-xl font-semibold">No pipelines yet</h2><p class="mt-2 text-base-content/60">
            Connect a trusted GitHub repository and push a workflow.
          </p>
        </div>
        <div
          :if={@pipelines != []}
          class="overflow-x-auto rounded-3xl border border-base-300 bg-base-100"
        >
          <table class="table">
            <thead>
              <tr>
                <th>Status</th><th>Workflow</th><th>Commit</th><th>Started</th>
              </tr>
            </thead>
            <tbody id="pipelines">
              <tr
                :for={pipeline <- @pipelines}
                id={"pipeline-#{pipeline.id}"}
                class="hover:bg-base-200/60"
              >
                <td>
                  <span class={["badge gap-2", status_class(pipeline.status)]}><span aria-hidden="true">●</span>{pipeline.status}</span>
                </td>
                <td>
                  <.link
                    navigate={~p"/pipelines/#{pipeline.id}"}
                    class="font-semibold link link-hover"
                  >{pipeline.workflow_name}</.link>
                </td>
                <td><code>{String.slice(pipeline.commit_sha, 0, 8)}</code></td><td>
                  {Calendar.strftime(pipeline.inserted_at, "%Y-%m-%d %H:%M UTC")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
