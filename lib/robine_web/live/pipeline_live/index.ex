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
        <.ui_state :if={@load_error} kind={:error} title="Pipelines are temporarily unavailable">
          Retrying automatically. Existing CI work continues in the background.
        </.ui_state>
        <.ui_state
          :if={@pipelines == [] and is_nil(@load_error)}
          kind={:empty}
          title="No pipelines yet"
          class="rounded-3xl p-12"
        >
          Connect a trusted GitHub repository and push a workflow.
        </.ui_state>
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
                  <.status_badge status={pipeline.status} />
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
