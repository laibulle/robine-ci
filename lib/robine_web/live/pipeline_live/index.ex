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
        <header class="flex flex-col justify-between gap-5 border-b border-base-300/70 pb-8 sm:flex-row sm:items-end">
          <div>
            <div class="mb-4 flex items-center gap-2 text-xs font-bold uppercase tracking-[0.18em] text-primary">
              <span class="size-1.5 rounded-full bg-primary shadow-[0_0_0_4px_color-mix(in_oklab,var(--color-primary)_15%,transparent)]"></span>
              Live execution
            </div><h1 class="text-4xl font-bold sm:text-5xl">
              Pipelines
            </h1><p class="mt-3 max-w-xl text-base-content/55">
              Every workflow run, from first trigger to final artifact.
            </p>
          </div>
          <div class="flex items-center gap-2 rounded-xl border border-base-300/70 bg-base-100/60 px-3 py-2 text-xs text-base-content/55">
            <span class="relative flex size-2"><span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-50"></span><span class="relative inline-flex size-2 rounded-full bg-success"></span></span>
            Auto-refreshing
          </div>
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
          class="surface-panel overflow-x-auto rounded-2xl"
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
                class="group transition-colors hover:bg-base-200/60"
              >
                <td>
                  <.status_badge status={pipeline.status} />
                </td>
                <td>
                  <.link
                    navigate={~p"/pipelines/#{pipeline.id}"}
                    class="font-semibold text-base-content transition-colors group-hover:text-primary"
                  >{pipeline.workflow_name}<span
                    aria-hidden="true"
                    class="ml-2 inline-block opacity-0 transition-all group-hover:translate-x-1 group-hover:opacity-100"
                  >→</span></.link>
                </td>
                <td>
                  <code class="rounded-md bg-base-200 px-2 py-1 text-xs">{String.slice(
                    pipeline.commit_sha,
                    0,
                    8
                  )}</code>
                </td><td class="text-sm text-base-content/55">
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
