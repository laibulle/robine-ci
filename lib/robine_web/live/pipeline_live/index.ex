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
            <div class="page-eyebrow mb-4">Live execution</div><h1 class="text-4xl font-bold sm:text-5xl">
              Pipelines
            </h1><p class="mt-3 max-w-xl text-base-content/55">
              Follow every run from its first trigger to the final artifact.
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
        <div :if={@pipelines != []} id="pipelines" class="grid gap-3">
          <article
            :for={pipeline <- @pipelines}
            id={"pipeline-#{pipeline.id}"}
            class="surface-panel group grid gap-4 rounded-2xl p-4 transition duration-200 hover:-translate-y-0.5 hover:border-primary/30 hover:shadow-panel sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-center sm:p-5"
          >
            <div class="grid size-11 place-items-center rounded-xl bg-base-200 text-base-content/50 transition group-hover:bg-primary/10 group-hover:text-primary">
              <.icon name="hero-bolt" class="size-5" />
            </div>
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2.5">
                <.link
                  navigate={~p"/pipelines/#{pipeline.id}"}
                  class="truncate text-base font-semibold transition-colors group-hover:text-primary"
                >{pipeline.workflow_name}</.link>
                <.status_badge status={pipeline.status} size="sm" />
              </div>
              <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/45">
                <span class="flex items-center gap-1.5"><.icon
                  name="hero-code-bracket"
                  class="size-3.5"
                /><code>{String.slice(pipeline.commit_sha, 0, 8)}</code></span>
                <time class="flex items-center gap-1.5"><.icon name="hero-clock" class="size-3.5" />{Calendar.strftime(
                  pipeline.inserted_at,
                  "%Y-%m-%d · %H:%M UTC"
                )}</time>
              </div>
            </div>
            <.link
              navigate={~p"/pipelines/#{pipeline.id}"}
              class="hidden size-9 place-items-center rounded-full border border-base-300 text-base-content/40 transition group-hover:border-primary/30 group-hover:bg-primary group-hover:text-primary-content sm:grid"
              aria-label={"Open #{pipeline.workflow_name}"}
            ><.icon name="hero-arrow-right" class="size-4" /></.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
