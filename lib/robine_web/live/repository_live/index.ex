defmodule RobineWeb.RepositoryLive.Index do
  use RobineWeb, :live_view

  alias Robine.{Pipelines, Repositories}

  @active_statuses [:created, :queued, :running, :cancelling]
  @providers ~w(all github)
  @attention_filters ~w(all attention healthy inactive)
  @sort_filters ~w(activity name connected)

  @impl true
  def mount(_params, _session, socket) do
    filters = default_filters()

    {:ok,
     socket
     |> assign(
       filters: filters,
       filter_form: to_form(filters, as: :filters),
       repository_load_error: false,
       repository_count: 0,
       result_count: 0,
       repository_summary: empty_repository_summary(),
       repository_spotlight: nil,
       available_repositories: [],
       available_count: 0,
       discovery_query: "",
       discovery_form: to_form(%{"query" => ""}, as: :discovery),
       discovery_provider: :github,
       discovery_state: :not_run,
       connect_repositories_open?: false
     )
     |> stream_configure(:repositories, dom_id: &"repository-#{&1.id}")
     |> stream_configure(:available_repositories,
       dom_id: &"available-repository-#{&1.provider_id}"
     )
     |> stream(:repositories, [])
     |> stream(:available_repositories, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = normalize_filters(params["filters"] || %{})

    {:noreply,
     socket
     |> assign(filters: filters, filter_form: to_form(filters, as: :filters))
     |> load_repositories()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = normalize_filters(filters)
    {:noreply, push_patch(socket, to: ~p"/repositories?#{compact_filters(filters)}")}
  end

  def handle_event("open-connect-repositories", _params, socket) do
    {:noreply, assign(socket, connect_repositories_open?: true)}
  end

  def handle_event("filter-discovery", %{"discovery" => %{"query" => query}}, socket) do
    query = query |> String.trim() |> String.slice(0, 100)

    {:noreply,
     socket
     |> assign(
       discovery_query: query,
       discovery_form: to_form(%{"query" => query}, as: :discovery)
     )
     |> refresh_available_stream()}
  end

  def handle_event("discover", _params, socket), do: discover(socket, :github)

  def handle_event("trust", params, socket) do
    input = %{
      provider_id: params["provider_id"],
      installation_id: params["installation_id"],
      full_name: params["full_name"]
    }

    trust_repository(socket, params, fn ->
      Repositories.trust_github_repository(input, socket.assigns.execution_context)
    end)
  end

  defp discover(socket, :github) do
    result = Repositories.discover_github_repositories(%{}, socket.assigns.execution_context)

    case result do
      {:ok, repositories} ->
        {:noreply,
         socket
         |> assign(
           available_repositories: repositories,
           discovery_provider: :github,
           discovery_state: :ready
         )
         |> refresh_available_stream()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only administrators can connect repositories.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(
           available_repositories: [],
           available_count: 0,
           discovery_provider: :github,
           discovery_state: :error
         )
         |> stream(:available_repositories, [], reset: true)}
    end
  end

  defp trust_repository(socket, params, callback) do
    case callback.() do
      {:ok, repository} ->
        remaining =
          Enum.reject(
            socket.assigns.available_repositories,
            &(&1.provider_id == String.to_integer(params["provider_id"]))
          )

        {:noreply,
         socket
         |> put_flash(:info, "#{repository.full_name} is now trusted.")
         |> assign(available_repositories: remaining)
         |> refresh_available_stream()
         |> load_repositories()}

      {:error, :repository_not_granted_to_github_app} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "GitHub no longer grants the App access to that repository. Refresh access and retry."
         )}

      {:error, :repository_not_granted_to_source_control} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The provider no longer grants access to that repository. Refresh access and retry."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The repository could not be trusted.")}
    end
  end

  defp load_repositories(socket) do
    case Repositories.list_repositories(%{}, socket.assigns.execution_context) do
      {:ok, repositories} ->
        enriched =
          repositories
          |> Enum.filter(&(&1.provider == :github))
          |> Enum.map(&enrich_repository(&1, socket.assigns.execution_context))

        filtered = filter_repositories(enriched, socket.assigns.filters)

        socket
        |> assign(
          repository_load_error: false,
          repository_count: length(enriched),
          result_count: length(filtered),
          repository_summary: summarize_repositories(enriched),
          repository_spotlight: repository_spotlight(enriched)
        )
        |> stream(:repositories, filtered, reset: true)

      {:error, _reason} ->
        assign(socket,
          repository_load_error: true,
          repository_count: 0,
          result_count: 0,
          repository_summary: empty_repository_summary(),
          repository_spotlight: nil
        )
    end
  end

  defp enrich_repository(repository, context) do
    case Pipelines.list_pipelines(%{repository_id: repository.id, limit: 20}, context) do
      {:ok, pipelines} ->
        latest = List.first(pipelines)

        repository
        |> Map.put(:latest_pipeline, latest)
        |> Map.put(:active_count, Enum.count(pipelines, &active_status?(&1.status)))
        |> Map.put(
          :workflow_count,
          pipelines |> Enum.map(& &1.workflow_name) |> Enum.uniq() |> length()
        )
        |> Map.put(:activity_state, activity_state(latest, pipelines))
        |> Map.put(:activity_error, false)

      {:error, _reason} ->
        repository
        |> Map.put(:latest_pipeline, nil)
        |> Map.put(:active_count, 0)
        |> Map.put(:workflow_count, 0)
        |> Map.put(:activity_state, :unknown)
        |> Map.put(:activity_error, true)
    end
  end

  defp activity_state(%{status: :failed}, _pipelines), do: :attention

  defp activity_state(_latest, pipelines) when pipelines != [] do
    if Enum.any?(pipelines, &active_status?(&1.status)), do: :attention, else: :healthy
  end

  defp activity_state(nil, _pipelines), do: :inactive

  defp filter_repositories(repositories, filters) do
    query = filters["query"] |> String.trim() |> String.downcase()

    repositories
    |> Enum.filter(fn repository ->
      (query == "" or String.contains?(String.downcase(repository.full_name), query)) and
        (filters["provider"] == "all" or to_string(repository.provider) == filters["provider"]) and
        (filters["attention"] == "all" or
           to_string(repository.activity_state) == filters["attention"])
    end)
    |> sort_repositories(filters["sort"])
  end

  defp sort_repositories(repositories, "name"),
    do: Enum.sort_by(repositories, &String.downcase(&1.full_name))

  defp sort_repositories(repositories, "connected"),
    do: Enum.sort_by(repositories, &DateTime.to_unix(&1.inserted_at, :microsecond), :desc)

  defp sort_repositories(repositories, _activity) do
    Enum.sort_by(
      repositories,
      &if(&1.latest_pipeline,
        do: DateTime.to_unix(&1.latest_pipeline.inserted_at, :microsecond),
        else: 0
      ),
      :desc
    )
  end

  defp refresh_available_stream(socket) do
    query = String.downcase(socket.assigns.discovery_query)

    filtered =
      Enum.filter(socket.assigns.available_repositories, fn repository ->
        query == "" or String.contains?(String.downcase(repository.full_name), query)
      end)

    socket
    |> assign(available_count: length(filtered))
    |> stream(:available_repositories, filtered, reset: true)
  end

  defp default_filters,
    do: %{"query" => "", "provider" => "all", "attention" => "all", "sort" => "activity"}

  defp normalize_filters(filters) do
    provider = if filters["provider"] in @providers, do: filters["provider"], else: "all"

    attention =
      if filters["attention"] in @attention_filters, do: filters["attention"], else: "all"

    sort = if filters["sort"] in @sort_filters, do: filters["sort"], else: "activity"

    %{
      "query" => filters["query"] |> to_string() |> String.slice(0, 100),
      "provider" => provider,
      "attention" => attention,
      "sort" => sort
    }
  end

  defp compact_filters(filters) do
    filters
    |> Enum.reject(fn
      {"query", ""} -> true
      {_key, "all"} -> true
      {"sort", "activity"} -> true
      _pair -> false
    end)
    |> Map.new()
    |> then(fn compact -> if compact == %{}, do: %{}, else: %{"filters" => compact} end)
  end

  defp active_filters?(filters), do: compact_filters(filters) != %{}
  defp active_status?(status), do: status in @active_statuses

  defp empty_repository_summary,
    do: %{attention: 0, active_runs: 0, healthy: 0, inactive: 0, unknown: 0}

  defp summarize_repositories(repositories) do
    Enum.reduce(repositories, empty_repository_summary(), fn repository, summary ->
      summary
      |> Map.update!(:active_runs, &(&1 + repository.active_count))
      |> Map.update!(repository.activity_state, &(&1 + 1))
    end)
  end

  defp repository_spotlight([]), do: nil

  defp repository_spotlight(repositories) do
    Enum.min_by(repositories, fn repository ->
      latest_at =
        if repository.latest_pipeline,
          do: DateTime.to_unix(repository.latest_pipeline.inserted_at, :microsecond),
          else: 0

      {spotlight_priority(repository), -latest_at}
    end)
  end

  defp spotlight_priority(%{latest_pipeline: %{status: :failed}}), do: 0
  defp spotlight_priority(%{active_count: active_count}) when active_count > 0, do: 1
  defp spotlight_priority(%{activity_state: :unknown}), do: 2
  defp spotlight_priority(%{activity_state: :healthy}), do: 3
  defp spotlight_priority(_repository), do: 4

  defp spotlight_eyebrow(%{latest_pipeline: %{status: :failed}}), do: "Failure to inspect"
  defp spotlight_eyebrow(%{active_count: active_count}) when active_count > 0, do: "Running now"
  defp spotlight_eyebrow(%{activity_state: :unknown}), do: "Signal unavailable"
  defp spotlight_eyebrow(%{activity_state: :healthy}), do: "Latest healthy signal"
  defp spotlight_eyebrow(_repository), do: "Ready for a first run"

  defp sort_label("name"), do: "Alphabetical"
  defp sort_label("connected"), do: "Newest connections"
  defp sort_label(_activity), do: "Latest activity"

  defp repository_owner(repository), do: repository.owner
  defp repository_name(repository), do: repository.name

  defp activity_label(:attention), do: "Needs attention"
  defp activity_label(:healthy), do: "Operating normally"
  defp activity_label(:inactive), do: "Waiting for a first run"
  defp activity_label(:unknown), do: "Activity unavailable"

  defp activity_icon(:attention), do: "hero-exclamation-triangle"
  defp activity_icon(:healthy), do: "hero-check-circle"
  defp activity_icon(:inactive), do: "hero-moon"
  defp activity_icon(:unknown), do: "hero-question-mark-circle"

  defp provider_label(:github), do: "GitHub"

  defp discovery_installation(:github, repository),
    do: " · Installation #{repository.installation_id}"

  defp relative_time(nil), do: "No runs yet"

  defp relative_time(datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%Y-%m-%d")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:repositories}>
      <section class="space-y-8">
        <header class="repository-hero">
          <div class="repository-hero-copy">
            <div class="flex items-center gap-3">
              <span class="repository-hero-index">01</span>
              <p class="page-eyebrow">Repository operations</p>
            </div>
            <h1 class="repository-hero-title">Repositories</h1>
            <p class="repository-hero-description">
              Current execution posture across every project Robine is trusted to run.
            </p>
            <div class="mt-8 flex flex-wrap items-center gap-3">
              <a
                :if={@current_actor.role == :administrator}
                id="connect-repository-action"
                href="#connect-repositories"
                phx-click="open-connect-repositories"
                class="btn btn-primary"
              >
                <.icon name="hero-plus" class="size-4" /> Connect repository
              </a>
              <.link navigate={~p"/pipelines"} class="repository-text-link">
                All pipelines <.icon name="hero-arrow-long-right" class="size-4" />
              </.link>
            </div>
          </div>

          <div id="repository-focus" class="repository-landscape">
            <span class="repository-landscape-word" aria-hidden="true">SIGNAL</span>
            <span class="repository-landscape-axis" aria-hidden="true"></span>
            <span class="repository-landscape-orbit repository-landscape-orbit-one" aria-hidden="true"></span>
            <span class="repository-landscape-orbit repository-landscape-orbit-two" aria-hidden="true"></span>

            <.link
              :if={@repository_spotlight}
              navigate={~p"/repositories/#{@repository_spotlight.id}"}
              class="repository-focus-link group"
              aria-label={"Open priority repository #{@repository_spotlight.full_name}"}
            >
              <span class="repository-focus-kicker">
                <span class="repository-focus-beacon" aria-hidden="true"></span>
                {spotlight_eyebrow(@repository_spotlight)}
              </span>
              <span class="repository-focus-name">
                <span>{@repository_spotlight.owner} /</span>
                <strong>{@repository_spotlight.name}</strong>
              </span>
              <%= if @repository_spotlight.latest_pipeline do %>
                <span class="repository-focus-workflow">
                  <.status_badge status={@repository_spotlight.latest_pipeline.status} size="sm" />
                  <span class="truncate">{@repository_spotlight.latest_pipeline.workflow_name}</span>
                </span>
              <% else %>
                <span class="repository-focus-workflow">No pipeline has run yet</span>
              <% end %>
              <span class="repository-focus-meta">
                <span><strong>{@repository_spotlight.active_count}</strong> active</span>
                <span><strong>{@repository_spotlight.workflow_count}</strong> workflows</span>
                <span>
                  {relative_time(
                    @repository_spotlight.latest_pipeline &&
                      @repository_spotlight.latest_pipeline.inserted_at
                  )}
                </span>
              </span>
              <span class="repository-focus-action">
                Inspect repository <.icon name="hero-arrow-up-right" class="size-4" />
              </span>
            </.link>

            <div :if={is_nil(@repository_spotlight)} class="repository-focus-empty">
              <.icon name="hero-code-bracket-square" class="size-6" />
              <p>No repository signal yet</p>
              <span>Connect a trusted project to begin.</span>
            </div>
          </div>

          <dl id="repository-overview" class="repository-pulse" aria-label="Repository overview">
            <div>
              <dt>Trusted</dt>
              <dd>{@repository_count}</dd>
            </div>
            <div>
              <dt>Needs attention</dt>
              <dd>{@repository_summary.attention}</dd>
            </div>
            <div>
              <dt>Runs in motion</dt>
              <dd>{@repository_summary.active_runs}</dd>
            </div>
            <div>
              <dt>Quietly healthy</dt>
              <dd>{@repository_summary.healthy}</dd>
            </div>
          </dl>
        </header>

        <.form
          for={@filter_form}
          id="repository-filters"
          phx-change="filter"
          class="repository-filter-bar grid gap-3 py-4 md:grid-cols-2 md:items-end xl:grid-cols-[minmax(18rem,1fr)_10rem_11rem_11rem_auto]"
        >
          <div class="repository-search-wrap">
            <.icon name="hero-magnifying-glass" class="repository-search-icon size-4" />
            <.input
              field={@filter_form[:query]}
              id="repository-search"
              type="search"
              label="Find a repository"
              placeholder="Search owner or project…"
              phx-debounce="250"
            />
          </div>
          <.input
            field={@filter_form[:provider]}
            id="repository-provider-filter"
            type="select"
            label="Provider"
            options={[
              {"All providers", "all"},
              {"GitHub", "github"}
            ]}
          />
          <.input
            field={@filter_form[:attention]}
            id="repository-attention-filter"
            type="select"
            label="Activity"
            options={[
              {"All activity", "all"},
              {"Needs attention", "attention"},
              {"Passing", "healthy"},
              {"No runs", "inactive"}
            ]}
          />
          <.input
            field={@filter_form[:sort]}
            id="repository-sort"
            type="select"
            label="Sort by"
            options={[
              {"Last activity", "activity"},
              {"Repository name", "name"},
              {"Recently connected", "connected"}
            ]}
          />
          <.link
            :if={active_filters?(@filters)}
            patch={~p"/repositories"}
            id="clear-repository-filters"
            class="btn btn-ghost mb-0.5"
          >Clear</.link>
        </.form>

        <div class="repository-catalogue-heading">
          <p id="repository-result-count" class="flex items-center gap-2 font-bold">
            <span class="repository-catalogue-number">02</span>
            {@result_count} {if(@result_count == 1, do: "repository", else: "repositories")}
            <span :if={@result_count != @repository_count} class="font-normal text-base-content/45">
              of {@repository_count}
            </span>
          </p>
          <span class="flex items-center gap-1.5 text-xs text-base-content/40">
            <.icon name="hero-arrows-up-down" class="size-3.5" /> {sort_label(@filters["sort"])}
          </span>
        </div>

        <.ui_state
          :if={@repository_load_error}
          kind={:error}
          title="Trusted repositories are temporarily unavailable"
          class="rounded-2xl p-10"
        >
          Reload after checking database health. Existing CI work continues in the background.
        </.ui_state>

        <.ui_state
          :if={@repository_count == 0 and not @repository_load_error}
          kind={:empty}
          title="No trusted repository"
          class="rounded-2xl p-10"
        >
          Connect a source-control provider, discover its repositories, then explicitly trust one.
        </.ui_state>

        <.ui_state
          :if={@repository_count > 0 and @result_count == 0}
          kind={:empty}
          title="No matching repository"
          class="rounded-2xl p-10"
        >
          Adjust the search or clear filters.
          <:actions>
            <.link patch={~p"/repositories"} class="btn btn-primary btn-sm">Clear filters</.link>
          </:actions>
        </.ui_state>

        <div id="trusted-repositories" phx-update="stream" class="repository-ledger">
          <article
            :for={{id, repository} <- @streams.repositories}
            id={id}
            data-activity={repository.activity_state}
            class="repository-card group relative focus-within:outline-3 focus-within:outline-offset-2 focus-within:outline-primary"
          >
            <div class="repository-card-signal" aria-hidden="true"></div>
            <div class="repository-card-body">
              <div class="repository-card-identity">
                <span class="repository-row-number" aria-hidden="true"></span>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="repository-provider">{provider_label(repository.provider)}</span>
                    <span class="repository-trust"><.icon
                      name="hero-lock-closed-micro"
                      class="size-3"
                    /> Trusted</span>
                    <span class="repository-health">Health unchecked</span>
                  </div>
                  <.link
                    navigate={~p"/repositories/#{repository.id}"}
                    class="repository-name"
                    aria-label={"Open #{repository.full_name}"}
                  >
                    <span>{repository_owner(repository)}</span><span class="repository-name-slash">/</span><strong>{repository_name(
                      repository
                    )}</strong>
                  </.link>
                  <p class="repository-activity-copy">
                    <.icon name={activity_icon(repository.activity_state)} class="size-3.5" />
                    {activity_label(repository.activity_state)}
                    <span aria-hidden="true">·</span> {repository.provider_instance}
                  </p>
                </div>
              </div>

              <div class="repository-latest-signal">
                <p>Latest signal</p>
                <%= if repository.latest_pipeline do %>
                  <div class="mt-2 flex min-w-0 items-center gap-2">
                    <.status_badge status={repository.latest_pipeline.status} size="sm" />
                    <span class="truncate text-sm font-bold">{repository.latest_pipeline.workflow_name}</span>
                  </div>
                  <span class="mt-1 block text-xs text-base-content/40">
                    {relative_time(repository.latest_pipeline.inserted_at)}
                  </span>
                <% else %>
                  <span class="mt-2 block text-sm font-semibold text-base-content/45">No pipelines yet</span>
                <% end %>
              </div>

              <dl class="repository-card-metrics">
                <div>
                  <dt>Active</dt>
                  <dd>{repository.active_count}</dd>
                </div>
                <div>
                  <dt>Workflows</dt>
                  <dd>{repository.workflow_count}</dd>
                </div>
              </dl>
            </div>
            <span class="repository-card-arrow" aria-hidden="true">
              <.icon name="hero-arrow-up-right" class="size-4" />
            </span>
          </article>
        </div>

        <details
          :if={@current_actor.role == :administrator}
          id="connect-repositories"
          open={@connect_repositories_open? or @discovery_state != :not_run}
          class="connect-repositories-panel scroll-mt-8 rounded-2xl"
        >
          <summary class="group cursor-pointer list-none rounded-2xl p-5 focus-visible:outline-3 focus-visible:outline-primary sm:p-6">
            <span class="flex items-center gap-4">
              <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary">
                <.icon name="hero-link" class="size-5" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block font-extrabold">Connect another project</span>
                <span class="mt-0.5 block text-xs font-normal text-base-content/45">Discover, review, then grant execution trust</span>
              </span>
              <span class="hidden text-[0.65rem] font-bold uppercase tracking-wider text-base-content/35 sm:block">Admin only</span>
              <.icon name="hero-chevron-down" class="size-4 transition group-open:rotate-180" />
            </span>
          </summary>
          <div class="border-t border-base-300/70 p-5 sm:p-6">
            <p class="max-w-2xl text-sm text-base-content/60">
              Verify GitHub App access, then explicitly authorize repositories to execute trusted CI code.
            </p>
            <div class="mt-5">
              <button
                id="discover-github-repositories"
                phx-click="discover"
                phx-disable-with="Refreshing…"
                class={["btn btn-sm", @discovery_provider == :github && "btn-primary"]}
                aria-pressed={@discovery_provider == :github}
              >GitHub</button>
            </div>

            <p :if={@discovery_state == :not_run} class="mt-5 text-sm text-base-content/60">
              No provider access has been queried in this browser session.
            </p>
            <.ui_state
              :if={@discovery_state == :error}
              kind={:degraded}
              title={"#{provider_label(@discovery_provider)} repositories are unavailable"}
              class="mt-5"
            >
              Check credentials and connectivity, then retry. Trusted repositories remain active.
            </.ui_state>
            <.ui_state
              :if={@discovery_state == :ready and @available_repositories == []}
              kind={:empty}
              title={"No repository is available from #{provider_label(@discovery_provider)}"}
              class="mt-5 p-6"
            >
              Update provider access, then refresh.
            </.ui_state>

            <.form
              :if={@discovery_state == :ready and @available_repositories != []}
              for={@discovery_form}
              id="repository-discovery-filter"
              phx-change="filter-discovery"
              class="mt-5 max-w-md"
            >
              <.input
                field={@discovery_form[:query]}
                type="search"
                label="Filter available repositories"
                placeholder="Owner or repository"
                phx-debounce="200"
              />
            </.form>

            <p
              :if={@discovery_state == :ready and @available_repositories != []}
              class="mt-4 text-xs text-base-content/45"
            >
              {@available_count} available
            </p>
            <p
              :if={
                @discovery_state == :ready and @available_repositories != [] and
                  @available_count == 0
              }
              class="mt-3 rounded-xl border border-dashed border-base-300 p-5 text-sm text-base-content/55"
            >
              No available repository matches this search.
            </p>
            <ul id="available-repositories" phx-update="stream" class="mt-3 grid gap-3">
              <li
                :for={{id, repository} <- @streams.available_repositories}
                id={id}
                class="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-base-300 p-4"
              >
                <div>
                  <p class="font-semibold">{repository.full_name}</p>
                  <p class="text-xs text-base-content/55">
                    {provider_label(@discovery_provider)} · Instance {Map.get(
                      repository,
                      :provider_instance,
                      "default"
                    )}{discovery_installation(@discovery_provider, repository)} · {if repository.private,
                      do: "Private",
                      else: "Public"}
                  </p>
                </div>
                <button
                  phx-click="trust"
                  phx-disable-with="Verifying…"
                  phx-value-provider_id={repository.provider_id}
                  phx-value-installation_id={repository.installation_id}
                  phx-value-full_name={repository.full_name}
                  data-confirm={"Trust #{repository.full_name}? Its workflows will be authorized to execute CI code on this Robine instance."}
                  class="btn btn-primary btn-sm"
                >Trust repository</button>
              </li>
            </ul>
          </div>
        </details>
      </section>
    </Layouts.app>
    """
  end
end
