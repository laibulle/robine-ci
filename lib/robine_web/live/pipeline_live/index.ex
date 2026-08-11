defmodule RobineWeb.PipelineLive.Index do
  use RobineWeb, :live_view

  alias Robine.{Pipelines, Repositories}

  @refresh_interval 2_000
  @active_statuses [:created, :queued, :running, :cancelling]
  @status_filters ~w(all active failed succeeded cancelled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     socket
     |> assign(
       filters: default_filters(),
       filter_form: to_form(default_filters(), as: :filters),
       repositories: [],
       result_count: 0,
       total_count: 0,
       history_count: 0,
       watch_count: 0,
       load_error: nil,
       last_updated_at: nil,
       data_fingerprint: nil
     )
     |> stream_configure(:watch_pipelines, dom_id: &"pipeline-#{&1.id}")
     |> stream_configure(:history_pipelines, dom_id: &"pipeline-#{&1.id}")
     |> stream(:watch_pipelines, [])
     |> stream(:history_pipelines, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = normalize_filters(params["filters"] || %{})

    {:noreply,
     socket
     |> assign(filters: filters, filter_form: to_form(filters, as: :filters))
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = normalize_filters(filters)
    {:noreply, push_patch(socket, to: ~p"/pipelines?#{compact_filters(filters)}")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    context = socket.assigns.execution_context

    with {:ok, pipelines} <- Pipelines.list_pipelines(%{limit: 50}, context),
         {:ok, repositories} <- Repositories.list_repositories(%{}, context) do
      repository_names = Map.new(repositories, &{&1.id, &1.full_name})

      pipelines =
        Enum.map(pipelines, fn pipeline ->
          pipeline
          |> Map.put(
            :repository_name,
            Map.get(repository_names, pipeline.repository_id, "Unknown repository")
          )
          |> Map.put(:duration_label, duration_label(pipeline))
          |> Map.put(:relative_time, relative_time(pipeline.inserted_at))
          |> Map.put(:day_label, Calendar.strftime(pipeline.inserted_at, "%A, %B %-d"))
        end)

      filtered = filter_pipelines(pipelines, socket.assigns.filters)
      {watched, history} = split_watchlist(filtered)
      history = mark_day_boundaries(history)
      fingerprint = :erlang.phash2({watched, history})

      socket =
        assign(socket,
          repositories: repositories,
          total_count: length(pipelines),
          result_count: length(filtered),
          watch_count: length(watched),
          history_count: length(history),
          load_error: nil,
          last_updated_at: DateTime.utc_now()
        )

      if socket.assigns.data_fingerprint == fingerprint do
        socket
      else
        socket
        |> assign(data_fingerprint: fingerprint)
        |> stream(:watch_pipelines, watched, reset: true)
        |> stream(:history_pipelines, history, reset: true)
      end
    else
      {:error, reason} ->
        assign(socket, load_error: inspect(reason), last_updated_at: DateTime.utc_now())
    end
  end

  defp filter_pipelines(pipelines, filters) do
    query = filters["query"] |> String.trim() |> String.downcase()

    Enum.filter(pipelines, fn pipeline ->
      matches_query?(pipeline, query) and
        matches_status?(pipeline.status, filters["status"]) and
        matches_repository?(pipeline.repository_id, filters["repository"])
    end)
  end

  defp matches_query?(_pipeline, ""), do: true

  defp matches_query?(pipeline, query) do
    [
      pipeline.workflow_name,
      pipeline.repository_name,
      pipeline.commit_sha,
      pipeline.source_ref || ""
    ]
    |> Enum.any?(&String.contains?(String.downcase(&1), query))
  end

  defp matches_status?(_status, "all"), do: true
  defp matches_status?(status, "active"), do: active_status?(status)
  defp matches_status?(:failed, "failed"), do: true
  defp matches_status?(:succeeded, "succeeded"), do: true
  defp matches_status?(:cancelled, "cancelled"), do: true
  defp matches_status?(_status, _filter), do: false

  defp matches_repository?(_repository_id, "all"), do: true
  defp matches_repository?(repository_id, filter), do: repository_id == filter

  defp split_watchlist(pipelines) do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    Enum.split_with(pipelines, fn pipeline ->
      active_status?(pipeline.status) or
        (pipeline.status == :failed and DateTime.compare(pipeline.inserted_at, cutoff) != :lt)
    end)
  end

  defp mark_day_boundaries(pipelines) do
    pipelines
    |> Enum.map_reduce(nil, fn pipeline, previous_date ->
      date = DateTime.to_date(pipeline.inserted_at)
      {Map.put(pipeline, :starts_day?, date != previous_date), date}
    end)
    |> elem(0)
  end

  defp duration_label(%{started_at: nil}), do: "Not started"

  defp duration_label(%{started_at: started_at, finished_at: finished_at}) do
    finish = finished_at || DateTime.utc_now()
    format_duration(max(DateTime.diff(finish, started_at, :second), 0))
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3_600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    "#{hours}h #{minutes}m"
  end

  defp relative_time(datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 10 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%Y-%m-%d")
    end
  end

  defp default_filters, do: %{"query" => "", "status" => "all", "repository" => "all"}

  defp normalize_filters(filters) when is_map(filters) do
    status = if filters["status"] in @status_filters, do: filters["status"], else: "all"
    repository = filters["repository"] || "all"

    %{
      "query" => filters["query"] |> to_string() |> String.slice(0, 100),
      "status" => status,
      "repository" => repository |> to_string() |> String.slice(0, 64)
    }
  end

  defp compact_filters(filters) do
    filters
    |> Enum.reject(fn
      {"query", ""} -> true
      {_key, "all"} -> true
      _pair -> false
    end)
    |> Map.new()
    |> then(fn compact -> if compact == %{}, do: %{}, else: %{"filters" => compact} end)
  end

  defp active_filters?(filters), do: compact_filters(filters) != %{}
  defp active_status?(status), do: status in @active_statuses

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:pipelines}>
      <section class="space-y-7">
        <.page_header
          eyebrow="The workshop"
          title="Pipelines"
          description="Every commit leaves a clear trail. Follow what is moving, find what needs care, and keep shipping."
        >
          <:actions>
            <div
              id="pipeline-refresh-status"
              class={[
                "flex items-center gap-2 self-start rounded-xl border px-3 py-2 text-xs sm:self-auto",
                @load_error && "border-error/25 bg-error/5 text-error",
                !@load_error && "border-base-300/70 bg-base-100/60 text-base-content/55"
              ]}
              role="status"
            >
              <span class={[
                "size-2 rounded-full",
                @load_error && "bg-error",
                !@load_error && "bg-success"
              ]}></span>
              <%= if @load_error do %>
                Reconnecting…
              <% else %>
                Up to date · {if(@last_updated_at,
                  do: relative_time(@last_updated_at),
                  else: "loading"
                )}
              <% end %>
            </div>
          </:actions>
        </.page_header>

        <.ui_state :if={@load_error} kind={:error} title="Pipelines are temporarily unavailable">
          Last known results remain visible. Retrying automatically while CI work continues.
        </.ui_state>

        <.form
          for={@filter_form}
          id="pipeline-filters"
          phx-change="filter"
          class="surface-panel grid gap-3 rounded-2xl p-3 md:grid-cols-[minmax(15rem,1fr)_12rem_15rem_auto] md:items-end"
        >
          <.input
            field={@filter_form[:query]}
            id="pipeline-search"
            type="search"
            label="Search pipelines"
            placeholder="Workflow, repository, ref, or SHA"
            phx-debounce="250"
          />
          <.input
            field={@filter_form[:status]}
            id="pipeline-status-filter"
            type="select"
            label="Status"
            options={[
              {"All statuses", "all"},
              {"Active", "active"},
              {"Failed", "failed"},
              {"Succeeded", "succeeded"},
              {"Cancelled", "cancelled"}
            ]}
          />
          <.input
            field={@filter_form[:repository]}
            id="pipeline-repository-filter"
            type="select"
            label="Repository"
            options={[{"All repositories", "all"} | Enum.map(@repositories, &{&1.full_name, &1.id})]}
          />
          <.link
            :if={active_filters?(@filters)}
            patch={~p"/pipelines"}
            id="clear-pipeline-filters"
            class="btn btn-ghost mb-0.5"
          >
            Clear
          </.link>
        </.form>

        <div class="flex items-center justify-between gap-4 text-sm">
          <p id="pipeline-result-count" class="font-semibold">
            {@result_count} {if(@result_count == 1, do: "pipeline", else: "pipelines")}
            <span :if={@result_count != @total_count} class="font-normal text-base-content/45">
              of {@total_count}
            </span>
          </p>
          <p class="text-xs text-base-content/40">Showing the 50 most recent runs</p>
        </div>

        <.ui_state
          :if={@total_count == 0 and is_nil(@load_error)}
          kind={:empty}
          title="No pipelines yet"
          class="rounded-2xl p-12"
        >
          Connect a trusted repository and push a workflow.
        </.ui_state>

        <.ui_state
          :if={@total_count > 0 and @result_count == 0}
          kind={:empty}
          title="No matching pipelines"
          class="rounded-2xl p-10"
        >
          Adjust your search or clear the filters to see recent runs.
          <:actions>
            <.link patch={~p"/pipelines"} class="btn btn-primary btn-sm">Clear filters</.link>
          </:actions>
        </.ui_state>

        <section
          :if={@watch_count > 0}
          id="pipeline-watchlist"
          aria-labelledby="watchlist-title"
          class="space-y-3"
        >
          <div class="flex items-center justify-between">
            <div>
              <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-error">
                Needs attention
              </p>
              <h2 id="watchlist-title" class="mt-1 text-xl font-bold">Watch now</h2>
            </div>
            <span class="rounded-full bg-error/10 px-2.5 py-1 text-xs font-bold text-error">{@watch_count}</span>
          </div>
          <div id="watch-pipelines" phx-update="stream" class="grid gap-3 lg:grid-cols-2">
            <.pipeline_row
              :for={{id, pipeline} <- @streams.watch_pipelines}
              id={id}
              pipeline={pipeline}
              emphasis
            />
          </div>
        </section>

        <section
          :if={@history_count > 0}
          id="pipeline-history"
          aria-labelledby="history-title"
          class="space-y-3"
        >
          <div class="flex items-center justify-between border-b border-base-300/70 pb-3">
            <h2 id="history-title" class="text-xl font-bold">Recent history</h2>
            <span class="text-xs text-base-content/40">Newest first</span>
          </div>
          <div id="history-pipelines" phx-update="stream" class="space-y-2">
            <div :for={{id, pipeline} <- @streams.history_pipelines} id={id} class="contents">
              <h3
                :if={pipeline.starts_day?}
                class="pb-1 pt-4 text-xs font-bold uppercase tracking-[0.12em] text-base-content/40 first:pt-0"
              >
                {pipeline.day_label}
              </h3>
              <.pipeline_row id={"row-#{pipeline.id}"} pipeline={pipeline} />
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :pipeline, :map, required: true
  attr :emphasis, :boolean, default: false

  defp pipeline_row(assigns) do
    ~H"""
    <article
      id={@id}
      class={[
        "surface-panel group relative grid gap-3 overflow-hidden rounded-xl p-4 transition duration-200 hover:-translate-y-0.5 hover:border-primary/35 hover:shadow-panel focus-within:outline-3 focus-within:outline-offset-2 focus-within:outline-primary sm:grid-cols-[minmax(0,1.5fr)_minmax(10rem,0.8fr)_auto] sm:items-center",
        @emphasis && @pipeline.status == :failed && "border-error/30 bg-error/[0.035]",
        @emphasis && active_status?(@pipeline.status) && "border-info/30 bg-info/[0.035]"
      ]}
    >
      <div class="min-w-0">
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <.status_badge status={@pipeline.status} size="sm" />
          <.link
            navigate={~p"/pipelines/#{@pipeline.id}"}
            class="truncate font-bold after:absolute after:inset-0 group-hover:text-primary"
            aria-label={"Open #{@pipeline.workflow_name} in #{@pipeline.repository_name}"}
          >
            {@pipeline.workflow_name}
          </.link>
        </div>
        <p class="mt-1.5 truncate text-sm font-medium text-base-content/65">
          {@pipeline.repository_name}
        </p>
      </div>

      <div class="min-w-0 text-xs text-base-content/50">
        <div class="flex items-center gap-2">
          <.icon
            name={if(@pipeline.trigger == "tag", do: "hero-tag", else: "hero-code-bracket")}
            class="size-3.5 shrink-0"
          />
          <span class="truncate font-medium text-base-content/70">{@pipeline.source_ref ||
            @pipeline.trigger}</span>
          <code class="shrink-0 rounded bg-base-200 px-1.5 py-0.5">{String.slice(
            @pipeline.commit_sha,
            0,
            8
          )}</code>
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
          <span class="flex items-center gap-1"><.icon name="hero-user" class="size-3.5" />{@pipeline.actor}</span>
          <span class="flex items-center gap-1"><.icon name="hero-play" class="size-3.5" />{@pipeline.trigger}</span>
        </div>
        <.link
          :if={@pipeline.failure_job}
          navigate={~p"/pipelines/#{@pipeline.id}/jobs/#{@pipeline.failure_job.id}"}
          class="relative z-10 mt-2 inline-flex items-center gap-1.5 rounded-md font-bold text-error underline-offset-4 hover:underline"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5" />
          Failed in {@pipeline.failure_job.job_key}<span class="sr-only">— view failure</span>
        </.link>
      </div>

      <div class="flex items-center justify-between gap-4 border-t border-base-300/60 pt-3 text-xs sm:block sm:border-0 sm:pt-0 sm:text-right">
        <span class="font-bold text-base-content/75">{@pipeline.duration_label}</span>
        <time
          datetime={DateTime.to_iso8601(@pipeline.inserted_at)}
          title={Calendar.strftime(@pipeline.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
          class="mt-0.5 block text-base-content/45"
        >
          {@pipeline.relative_time}
        </time>
      </div>

      <div class="pointer-events-none absolute right-3 top-1/2 hidden -translate-y-1/2 text-primary opacity-0 transition group-hover:translate-x-0.5 group-hover:opacity-100 xl:block">
        <.icon name="hero-arrow-right" class="size-4" />
      </div>
    </article>
    """
  end
end
