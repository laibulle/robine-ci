defmodule RobineWeb.WorkflowRevisionLive.Show do
  use RobineWeb, :live_view

  alias Robine.Pipelines

  @impl true
  def mount(%{"id" => pipeline_id}, _session, socket) do
    case Pipelines.workflow_revision(
           %{pipeline_id: pipeline_id},
           socket.assigns.execution_context
         ) do
      {:ok, revision} ->
        {:ok, assign(socket, pipeline_id: pipeline_id, revision: revision)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Workflow revision not found.")
         |> push_navigate(to: ~p"/pipelines/#{pipeline_id}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <.link navigate={~p"/pipelines/#{@pipeline_id}"} class="link text-sm">
            ← Pipeline
          </.link>
          <p class="mt-5 text-sm font-semibold uppercase tracking-[0.2em] text-primary">
            Immutable workflow revision
          </p>
          <h1 id="workflow-revision-title" class="mt-2 text-3xl font-bold break-all">
            {@revision.path}
          </h1>
          <dl class="mt-5 grid gap-4 sm:grid-cols-2">
            <div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">SHA-256</dt>
              <dd id="workflow-revision-digest" class="mt-1 break-all font-mono text-sm">
                {@revision.digest}
              </dd>
            </div>
            <div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">Captured</dt>
              <dd class="mt-1 text-sm">{DateTime.to_iso8601(@revision.created_at)}</dd>
            </div>
          </dl>
        </header>

        <section>
          <h2 class="text-xl font-semibold">Exact YAML</h2>
          <pre
            id="workflow-revision-source"
            class="mt-4 max-h-[42rem] overflow-auto rounded-2xl bg-neutral p-5 text-sm text-neutral-content"
          ><code>{@revision.source}</code></pre>
        </section>

        <section :if={map_size(@revision.included_sources) > 0} id="included-workflow-revisions">
          <h2 class="text-xl font-semibold">Included workflows</h2>
          <div class="mt-4 space-y-3">
            <details
              :for={{path, included} <- Enum.sort(@revision.included_sources)}
              class="rounded-2xl border border-base-300 bg-base-100 p-5"
            >
              <summary class="cursor-pointer">
                <span class="font-mono text-sm break-all">{path}</span>
                <span class="mt-1 block font-mono text-xs text-base-content/55 break-all">
                  {included["digest"]}
                </span>
              </summary>
              <pre class="mt-4 max-h-96 overflow-auto rounded-xl bg-neutral p-4 text-sm text-neutral-content"><code>{included["source"]}</code></pre>
            </details>
          </div>
        </section>

        <details class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <summary class="cursor-pointer font-semibold">Normalized execution graph</summary>
          <pre id="workflow-revision-graph" class="mt-4 overflow-auto text-sm"><code>{Jason.encode!(@revision.normalized_graph, pretty: true)}</code></pre>
        </details>
      </section>
    </Layouts.app>
    """
  end
end
