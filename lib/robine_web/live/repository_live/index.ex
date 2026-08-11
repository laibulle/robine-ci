defmodule RobineWeb.RepositoryLive.Index do
  use RobineWeb, :live_view

  alias Robine.{Pipelines, Repositories}

  @active_statuses [:created, :queued, :running, :cancelling]
  @providers ~w(all github gitlab forgejo)
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
       available_repositories: [],
       available_count: 0,
       discovery_query: "",
       discovery_form: to_form(%{"query" => ""}, as: :discovery),
       discovery_provider: :github,
       discovery_state: :not_run
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

  def handle_event("discover-provider", %{"provider" => provider_name}, socket) do
    case provider(provider_name) do
      {:ok, provider} -> discover(socket, provider)
      {:error, _reason} -> {:noreply, assign(socket, discovery_state: :error)}
    end
  end

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

  def handle_event("trust-provider", params, socket) do
    input = %{
      provider: params["provider"],
      provider_instance: params["provider_instance"],
      provider_id: params["provider_id"],
      installation_id: params["installation_id"],
      full_name: params["full_name"]
    }

    trust_repository(socket, params, fn ->
      Repositories.trust_source_control_repository(input, socket.assigns.execution_context)
    end)
  end

  defp discover(socket, provider) do
    result =
      if provider == :github do
        Repositories.discover_github_repositories(%{}, socket.assigns.execution_context)
      else
        Repositories.discover_source_control_repositories(
          %{provider: provider},
          socket.assigns.execution_context
        )
      end

    case result do
      {:ok, repositories} ->
        {:noreply,
         socket
         |> assign(
           available_repositories: repositories,
           discovery_provider: provider,
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
           discovery_provider: provider,
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
          Enum.map(repositories, &enrich_repository(&1, socket.assigns.execution_context))

        filtered = filter_repositories(enriched, socket.assigns.filters)

        socket
        |> assign(
          repository_load_error: false,
          repository_count: length(enriched),
          result_count: length(filtered)
        )
        |> stream(:repositories, filtered, reset: true)

      {:error, _reason} ->
        assign(socket, repository_load_error: true, repository_count: 0, result_count: 0)
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

  defp provider("github"), do: {:ok, :github}
  defp provider("gitlab"), do: {:ok, :gitlab}
  defp provider("forgejo"), do: {:ok, :forgejo}
  defp provider(_provider), do: {:error, :invalid_source_control_provider}

  defp provider_label(:github), do: "GitHub"
  defp provider_label(:gitlab), do: "GitLab"
  defp provider_label(:forgejo), do: "Forgejo"

  defp discovery_installation(:github, repository),
    do: " · Installation #{repository.installation_id}"

  defp discovery_installation(_provider, _repository), do: ""

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
      <section class="space-y-7">
        <.page_header
          eyebrow="Your source, close by"
          title="Repositories"
          description="The projects you care about, their latest signals, and exactly what Robine is trusted to run."
        >
          <:actions>
            <a
              :if={@current_actor.role == :administrator}
              href="#connect-repositories"
              class="btn btn-primary"
            >
              <.icon name="hero-plus" class="size-4" /> Connect repository
            </a>
          </:actions>
        </.page_header>

        <.form
          for={@filter_form}
          id="repository-filters"
          phx-change="filter"
          class="surface-panel grid gap-3 rounded-2xl p-3 md:grid-cols-2 md:items-end xl:grid-cols-[minmax(15rem,1fr)_11rem_12rem_11rem_auto]"
        >
          <.input
            field={@filter_form[:query]}
            id="repository-search"
            type="search"
            label="Search repositories"
            placeholder="Owner or repository"
            phx-debounce="250"
          />
          <.input
            field={@filter_form[:provider]}
            id="repository-provider-filter"
            type="select"
            label="Provider"
            options={[
              {"All providers", "all"},
              {"GitHub", "github"},
              {"GitLab", "gitlab"},
              {"Forgejo", "forgejo"}
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

        <div class="flex items-center justify-between text-sm">
          <p id="repository-result-count" class="font-semibold">
            {@result_count} {if(@result_count == 1, do: "repository", else: "repositories")}
            <span :if={@result_count != @repository_count} class="font-normal text-base-content/45">
              of {@repository_count}
            </span>
          </p>
          <span class="text-xs text-base-content/40">
            {if(@filters["sort"] == "name",
              do: "Sorted by name",
              else:
                if(@filters["sort"] == "connected",
                  do: "Newest connections first",
                  else: "Latest activity first"
                )
            )}
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

        <div id="trusted-repositories" phx-update="stream" class="grid gap-3">
          <article
            :for={{id, repository} <- @streams.repositories}
            id={id}
            class="surface-panel group relative grid gap-4 overflow-hidden rounded-2xl p-5 transition hover:-translate-y-0.5 hover:border-primary/35 hover:shadow-panel focus-within:outline-3 focus-within:outline-offset-2 focus-within:outline-primary md:grid-cols-[minmax(0,1.4fr)_minmax(12rem,0.8fr)_auto] md:items-center"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="badge badge-outline badge-sm">{provider_label(repository.provider)}</span>
                <span class="badge badge-success badge-sm">Trusted</span>
                <span class="badge badge-ghost badge-sm">Health unchecked</span>
              </div>
              <.link
                navigate={~p"/repositories/#{repository.id}"}
                class="mt-2 block truncate text-lg font-bold after:absolute after:inset-0 group-hover:text-primary"
                aria-label={"Open #{repository.full_name}"}
              >{repository.full_name}</.link>
              <p class="mt-1 text-xs text-base-content/45">Instance {repository.provider_instance}</p>
            </div>

            <div class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
              <div>
                <p class="text-[0.65rem] font-bold uppercase tracking-wider text-base-content/40">
                  Active
                </p>
                <p class="mt-1 font-bold">{repository.active_count}</p>
              </div>
              <div>
                <p class="text-[0.65rem] font-bold uppercase tracking-wider text-base-content/40">
                  Workflows
                </p>
                <p class="mt-1 font-bold">{repository.workflow_count}</p>
              </div>
              <div>
                <p class="text-[0.65rem] font-bold uppercase tracking-wider text-base-content/40">
                  Last activity
                </p>
                <p class="mt-1 font-semibold">
                  {relative_time(repository.latest_pipeline && repository.latest_pipeline.inserted_at)}
                </p>
              </div>
            </div>

            <div class="flex items-center justify-between gap-3 border-t border-base-300/60 pt-3 md:block md:border-0 md:pt-0 md:text-right">
              <%= if repository.latest_pipeline do %>
                <.status_badge status={repository.latest_pipeline.status} size="sm" />
                <p class="mt-1 max-w-44 truncate text-xs text-base-content/50">
                  {repository.latest_pipeline.workflow_name}
                </p>
              <% else %>
                <span class="text-xs font-semibold text-base-content/45">No pipelines yet</span>
              <% end %>
            </div>
          </article>
        </div>

        <details
          :if={@current_actor.role == :administrator}
          id="connect-repositories"
          open={@discovery_state != :not_run}
          class="surface-panel scroll-mt-8 rounded-2xl"
        >
          <summary class="cursor-pointer list-none rounded-2xl p-5 font-bold focus-visible:outline-3 focus-visible:outline-primary">
            <span class="flex items-center justify-between gap-3">
              <span><.icon name="hero-link" class="mr-2 inline size-4" />Connect repositories</span>
              <span class="text-xs font-normal text-base-content/45">Administrative action</span>
            </span>
          </summary>
          <div class="border-t border-base-300/70 p-5 sm:p-6">
            <p class="max-w-2xl text-sm text-base-content/60">
              Select a provider, verify live access, then explicitly authorize repositories to execute trusted CI code.
            </p>
            <div class="mt-5 flex flex-wrap gap-2" role="group" aria-label="Source-control provider">
              <button
                id="discover-github-repositories"
                phx-click="discover"
                phx-disable-with="Refreshing…"
                class={["btn btn-sm", @discovery_provider == :github && "btn-primary"]}
                aria-pressed={@discovery_provider == :github}
              >GitHub</button>
              <button
                id="discover-gitlab-repositories"
                phx-click="discover-provider"
                phx-value-provider="gitlab"
                phx-disable-with="Refreshing…"
                class={["btn btn-sm", @discovery_provider == :gitlab && "btn-primary"]}
                aria-pressed={@discovery_provider == :gitlab}
              >GitLab</button>
              <button
                id="discover-forgejo-repositories"
                phx-click="discover-provider"
                phx-value-provider="forgejo"
                phx-disable-with="Refreshing…"
                class={["btn btn-sm", @discovery_provider == :forgejo && "btn-primary"]}
                aria-pressed={@discovery_provider == :forgejo}
              >Forgejo</button>
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
                  phx-click={if @discovery_provider == :github, do: "trust", else: "trust-provider"}
                  phx-disable-with="Verifying…"
                  phx-value-provider={@discovery_provider}
                  phx-value-provider_instance={Map.get(repository, :provider_instance, "default")}
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
