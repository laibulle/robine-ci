defmodule RobineWeb.RepositoryLive.Show do
  use RobineWeb, :live_view
  alias Robine.{Pipelines, Repositories}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         %{provider: :github} = repository <- Enum.find(repositories, &(&1.id == id)),
         {:ok, pipelines} <-
           Pipelines.list_pipelines(
             %{repository_id: id, limit: 100},
             socket.assigns.execution_context
           ) do
      workflows = pipelines |> Enum.map(& &1.workflow_name) |> Enum.uniq() |> Enum.sort()

      {:ok,
       assign(socket,
         repository: repository,
         pipelines: pipelines,
         workflows: workflows,
         github_preflight: :not_run,
         github_preflight_checked_at: nil,
         manual_state: :not_run,
         manual_branch_form: to_form(%{"branch" => ""}, as: :branch_lookup),
         manual_head: nil,
         manual_workflows: [],
         manual_request_ids: %{},
         manual_error: nil,
         manual_input_errors: %{},
         schedule_state: :not_run,
         schedule_head: nil,
         scheduled_workflows: [],
         schedule_error: nil
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Repository not found.")
         |> push_navigate(to: ~p"/repositories")}
    end
  end

  @impl true
  def handle_event("check-github-installation", _params, socket) do
    result =
      Repositories.check_github_installation(
        %{repository_id: socket.assigns.repository.id},
        socket.assigns.execution_context
      )

    case result do
      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to check GitHub installations.")}

      result ->
        {:noreply,
         assign(socket,
           github_preflight: result,
           github_preflight_checked_at: DateTime.utc_now()
         )}
    end
  end

  def handle_event(
        "discover-manual-workflows",
        %{"branch_lookup" => %{"branch" => branch}},
        socket
      ) do
    case Repositories.list_manual_workflows(
           %{repository_id: socket.assigns.repository.id, branch: branch},
           socket.assigns.execution_context
         ) do
      {:ok, discovery} ->
        request_ids = Map.new(discovery.workflows, &{&1.path, Ecto.UUID.generate()})

        {:noreply,
         assign(socket,
           manual_state: :ready,
           manual_branch_form: to_form(%{"branch" => discovery.branch}, as: :branch_lookup),
           manual_head: %{branch: discovery.branch, commit_sha: discovery.commit_sha},
           manual_workflows: discovery.workflows,
           manual_request_ids: request_ids,
           manual_error: nil,
           manual_input_errors: %{}
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           manual_state: :error,
           manual_head: nil,
           manual_workflows: [],
           manual_error: "The source-control provider could not load manually enabled workflows.",
           manual_input_errors: %{}
         )}
    end
  end

  def handle_event("launch-manual-workflow", params, socket) do
    input = %{
      repository_id: socket.assigns.repository.id,
      branch: params["branch"],
      workflow_path: params["workflow_path"],
      request_id: params["request_id"],
      inputs: Map.get(params, "inputs", %{})
    }

    case Repositories.launch_manual_workflow(input, socket.assigns.execution_context) do
      {:ok, %{pipeline: pipeline}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Manual workflow queued at an immutable Git revision.")
         |> push_navigate(to: ~p"/pipelines/#{pipeline.id}")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to launch workflows.")}

      {:error, {:manual_input, id, reason}} ->
        {:noreply,
         assign(socket,
           manual_error: nil,
           manual_input_errors: %{id => "This input is #{manual_input_error(reason)}."}
         )}

      {:error, {:manual_inputs_undeclared, _names}} ->
        {:noreply,
         assign(socket,
           manual_error: "The submitted form contains undeclared inputs.",
           manual_input_errors: %{}
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           manual_error:
             "The branch head or workflow changed, or the provider is unavailable. Load workflows again, review the new immutable revision, then retry.",
           manual_input_errors: %{}
         )}
    end
  end

  def handle_event("discover-scheduled-workflows", _params, socket) do
    case Repositories.list_scheduled_workflows(
           %{repository_id: socket.assigns.repository.id},
           socket.assigns.execution_context
         ) do
      {:ok, discovery} ->
        {:noreply,
         assign(socket,
           schedule_state: :ready,
           schedule_head: %{branch: discovery.branch, commit_sha: discovery.commit_sha},
           scheduled_workflows: discovery.workflows,
           schedule_error: nil
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           schedule_state: :error,
           schedule_head: nil,
           scheduled_workflows: [],
           schedule_error: "The source-control provider could not load scheduled workflows."
         )}
    end
  end

  defp manual_input_error(:required), do: "required"
  defp manual_input_error(:invalid_choice), do: "not an allowed choice"
  defp manual_input_error(:invalid_boolean), do: "not a boolean"
  defp manual_input_error(_reason), do: "invalid"

  defp manual_form_id(path), do: "manual-workflow-#{:erlang.phash2(path)}"

  defp provider_label(:github), do: "GitHub"

  defp active_status?(status), do: status in [:created, :queued, :running, :cancelling]

  defp health_label(:not_run), do: "Health unchecked"
  defp health_label({:ok, %{status: :ok}}), do: "Connected"
  defp health_label({:ok, %{status: :degraded}}), do: "Degraded"
  defp health_label({:error, _reason}), do: "Unavailable"

  defp duration_label(%{started_at: nil}), do: "Not started"

  defp duration_label(%{started_at: started_at, finished_at: finished_at}) do
    seconds = max(DateTime.diff(finished_at || DateTime.utc_now(), started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h #{seconds |> rem(3_600) |> div(60)}m"
    end
  end

  defp relative_time(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)
    past? = seconds >= 0
    seconds = abs(seconds)

    value =
      cond do
        seconds < 60 -> "less than a minute"
        seconds < 3_600 -> "#{div(seconds, 60)}m"
        seconds < 86_400 -> "#{div(seconds, 3_600)}h"
        true -> "#{div(seconds, 86_400)}d"
      end

    if past?, do: "#{value} ago", else: "in #{value}"
  end

  defp schedule_description(cron) do
    case String.split(cron) do
      [minute, hour, "*", "*", "*"] ->
        "Every day at #{pad(hour)}:#{pad(minute)} UTC"

      [minute, hour, "*", "*", weekday] ->
        "Every #{weekday_name(weekday)} at #{pad(hour)}:#{pad(minute)} UTC"

      [minute, hour, day, "*", "*"] ->
        "Every month on day #{day} at #{pad(hour)}:#{pad(minute)} UTC"

      ["*/" <> interval, "*", "*", "*", "*"] ->
        "Every #{interval} minutes"

      _ ->
        "Custom UTC schedule"
    end
  end

  defp pad(value), do: String.pad_leading(value, 2, "0")

  defp weekday_name(value) do
    Map.get(
      %{
        "0" => "Sunday",
        "1" => "Monday",
        "2" => "Tuesday",
        "3" => "Wednesday",
        "4" => "Thursday",
        "5" => "Friday",
        "6" => "Saturday"
      },
      value,
      "weekday #{value}"
    )
  end

  defp next_occurrence(cron) do
    alias Robine.Workflows.Domain.CronExpression

    with {:ok, expression} <- CronExpression.parse(cron) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      first = DateTime.add(now, 60 - now.second, :second)

      Enum.find_value(0..46_080, fn offset ->
        candidate = DateTime.add(first, offset, :minute)
        if CronExpression.matches?(expression, candidate), do: candidate
      end)
    else
      _error -> nil
    end
  end

  defp latest_scheduled_pipeline(pipelines, workflow_name) do
    Enum.find(pipelines, &(&1.workflow_name == workflow_name and &1.trigger == "schedule"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:repositories}>
      <section class="space-y-8">
        <.page_header
          title={@repository.full_name}
          eyebrow="Close to the source"
          description={"#{provider_label(@repository.provider)} · #{@repository.provider_instance}"}
          breadcrumbs={[
            %{label: "Repositories", navigate: ~p"/repositories"},
            %{label: @repository.full_name}
          ]}
        >
          <:meta>
            <div class="flex flex-wrap items-center gap-2">
              <span class="badge badge-outline badge-sm">{provider_label(@repository.provider)}</span>
              <span class="badge badge-success badge-sm">Trusted</span>
              <span class="badge badge-ghost badge-sm">{health_label(@github_preflight)}</span>
            </div>
          </:meta>
          <:actions>
            <a href="#run-workflow" class="btn btn-primary btn-sm">Run workflow</a>
            <.link
              :if={@current_actor.role in [:administrator, :maintainer]}
              navigate={~p"/repositories/#{@repository.id}/secrets"}
              class="btn btn-outline btn-sm"
            >Manage secrets</.link>
          </:actions>
        </.page_header>
        <nav
          id="repository-section-navigation"
          class="sticky top-16 z-20 -mx-2 flex gap-1 overflow-x-auto rounded-xl border border-base-300/70 bg-base-100/90 p-1.5 shadow-sm backdrop-blur-xl lg:top-3"
          aria-label="Repository sections"
        >
          <a href="#overview" class="btn btn-ghost btn-sm">Overview</a>
          <a href="#recent-pipelines" class="btn btn-ghost btn-sm">Pipelines</a>
          <a href="#run-workflow" class="btn btn-ghost btn-sm">Manual run</a>
          <a href="#scheduled-workflows" class="btn btn-ghost btn-sm">Schedules</a>
          <a href="#previous-workflows" class="btn btn-ghost btn-sm">Workflows</a>
        </nav>

        <section id="overview" class="scroll-mt-8" aria-labelledby="overview-title">
          <h2 id="overview-title" class="sr-only">Repository overview</h2>
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.repository_stat
              label="Latest pipeline"
              value={
                if(List.first(@pipelines),
                  do: to_string(List.first(@pipelines).status),
                  else: "No runs"
                )
              }
              icon="hero-bolt"
            />
            <.repository_stat
              label="Active pipelines"
              value={Enum.count(@pipelines, &active_status?(&1.status))}
              icon="hero-play"
            />
            <.repository_stat
              label="Previously run workflows"
              value={length(@workflows)}
              icon="hero-command-line"
            />
            <.repository_stat
              label="Last activity"
              value={
                if(List.first(@pipelines),
                  do: relative_time(List.first(@pipelines).inserted_at),
                  else: "Never"
                )
              }
              icon="hero-clock"
            />
          </div>
        </section>

        <.repository_pipelines repository={@repository} pipelines={@pipelines} />
        <section class="surface-panel rounded-2xl p-5 sm:p-6" aria-labelledby="integration-title">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="integration-title" class="text-xl font-semibold">
                {provider_label(@repository.provider)} integration
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                Required repository permissions: Metadata read, Contents write, Checks write.
              </p>
            </div>
            <button
              :if={
                @repository.provider == :github and
                  @current_actor.role in [:administrator, :maintainer]
              }
              id="check-github-installation"
              phx-click="check-github-installation"
              phx-disable-with="Checking…"
              class="btn btn-outline btn-sm"
            >Check permissions</button>
          </div>
          <p :if={@github_preflight == :not_run} class="mt-4 text-sm text-base-content/60">
            Health has not been checked in this browser session. Trust remains enabled independently.
          </p>
          <div
            :if={match?({:ok, %{status: :ok}}, @github_preflight)}
            class="alert alert-success mt-4"
            role="status"
          >
            The configured provider connection has the required repository access.
          </div>
          <div
            :if={match?({:ok, %{status: :degraded}}, @github_preflight)}
            class="alert alert-warning mt-4 block"
            role="alert"
          >
            <p class="font-semibold">Installation permissions need attention.</p>
            <ul class="mt-2 list-disc space-y-1 pl-5">
              <li :for={missing <- elem(@github_preflight, 1).missing}>
                {missing.corrective_action} Current value: <code>{missing.actual}</code>.
              </li>
            </ul>
          </div>
          <div
            :if={match?({:error, _reason}, @github_preflight)}
            class="alert alert-error mt-4"
            role="alert"
          >
            {provider_label(@repository.provider)} could not verify this repository. Check credentials, connectivity, and provider access.
          </div>
          <p
            :if={@github_preflight_checked_at}
            id="integration-last-checked"
            class="mt-3 text-xs text-base-content/45"
          >
            Last checked
            <time
              datetime={DateTime.to_iso8601(@github_preflight_checked_at)}
              title={Calendar.strftime(@github_preflight_checked_at, "%Y-%m-%d %H:%M:%S UTC")}
            >{relative_time(@github_preflight_checked_at)}</time>
            in this session.
          </p>
        </section>
        <section
          id="run-workflow"
          class="surface-panel scroll-mt-8 rounded-2xl p-5 sm:p-6"
          aria-labelledby="run-workflow-title"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="run-workflow-title" class="text-xl font-semibold">Run a workflow</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Choose a branch. Robine resolves its current head to an immutable commit before launch.
              </p>
            </div>
            <.form
              for={@manual_branch_form}
              id="manual-branch-form"
              phx-submit="discover-manual-workflows"
              class="flex items-end gap-2"
            >
              <.input
                field={@manual_branch_form[:branch]}
                label="Branch"
                placeholder="Default branch"
              />
              <button
                id="discover-manual-workflows"
                phx-disable-with="Loading…"
                class="btn btn-outline mb-2"
              >Load workflows</button>
            </.form>
          </div>
          <p :if={@manual_state == :not_run} class="mt-4 text-sm text-base-content/60">
            No source-control request has been made in this session.
          </p>
          <div :if={@manual_state == :error} class="alert alert-error mt-4" role="alert">
            {@manual_error}
          </div>
          <div :if={@manual_head} id="manual-workflow-head" class="mt-4 rounded-2xl bg-base-200 p-4">
            <p class="text-sm font-semibold">Branch: {@manual_head.branch}</p>
            <code class="mt-1 block break-all text-xs">{@manual_head.commit_sha}</code>
          </div>
          <div
            :if={@manual_state == :ready and @manual_workflows == []}
            class="mt-4 rounded-2xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
          >
            No workflow at this revision declares <code>workflow_dispatch</code>.
          </div>
          <div
            :if={@manual_error && @manual_state == :ready}
            class="alert alert-error mt-4"
            role="alert"
          >
            {@manual_error}
          </div>
          <div :if={@manual_workflows != []} class="mt-5 grid gap-4 lg:grid-cols-2">
            <form
              :for={workflow <- @manual_workflows}
              id={manual_form_id(workflow.path)}
              phx-submit="launch-manual-workflow"
              class="rounded-2xl border border-base-300 p-5"
              data-confirm={"Run #{workflow.name} from #{@manual_head.branch} at #{String.slice(@manual_head.commit_sha, 0, 8)}? Review all inputs before continuing."}
            >
              <input type="hidden" name="workflow_path" value={workflow.path} />
              <input type="hidden" name="branch" value={@manual_head.branch} />
              <input type="hidden" name="request_id" value={@manual_request_ids[workflow.path]} />
              <h3 class="font-semibold">{workflow.name}</h3>
              <code class="mt-1 block break-all text-xs text-base-content/55">{workflow.path}</code>
              <div class="mt-5 space-y-4">
                <div :for={{id, input} <- Enum.sort(workflow.inputs)}>
                  <label for={"manual-input-#{id}"} class="form-control w-full">
                    <span class="label-text font-medium">
                      {id}{if input.required, do: " · required", else: ""}
                    </span>
                    <span :if={input.description} class="mb-2 text-xs text-base-content/55">
                      {input.description}
                    </span>
                    <select
                      :if={input.type in [:choice, :boolean]}
                      id={"manual-input-#{id}"}
                      name={"inputs[#{id}]"}
                      required={input.required}
                      aria-describedby={@manual_input_errors[id] && "manual-input-#{id}-error"}
                      class="select select-bordered w-full"
                    >
                      <option :if={input.required && is_nil(input.default)} value="" selected disabled>
                        Select…
                      </option>
                      <option
                        :for={value <- input.options || ["false", "true"]}
                        value={value}
                        selected={value == input.default}
                      >
                        {value}
                      </option>
                    </select>
                    <input
                      :if={input.type == :string}
                      id={"manual-input-#{id}"}
                      type="text"
                      name={"inputs[#{id}]"}
                      value={input.default || ""}
                      required={input.required}
                      maxlength="1024"
                      autocomplete="off"
                      aria-describedby={@manual_input_errors[id] && "manual-input-#{id}-error"}
                      class="input input-bordered w-full"
                    />
                  </label>
                  <p
                    :if={@manual_input_errors[id]}
                    id={"manual-input-#{id}-error"}
                    class="mt-1 text-sm text-error"
                    role="alert"
                  >
                    {@manual_input_errors[id]}
                  </p>
                </div>
              </div>
              <p class="mt-4 flex items-center gap-1 text-xs font-semibold text-warning">
                <.icon name="hero-shield-exclamation" class="size-3.5" />
                Do not enter passwords or tokens.
              </p>
              <button
                :if={@current_actor.role in [:administrator, :maintainer]}
                type="submit"
                phx-disable-with="Launching…"
                class="btn btn-primary mt-4 w-full"
              >Run at this revision</button>
              <p :if={@current_actor.role == :viewer} class="mt-4 text-sm text-base-content/60">
                Maintainer access is required to launch this workflow.
              </p>
            </form>
          </div>
        </section>
        <section
          id="scheduled-workflows"
          class="surface-panel scroll-mt-8 rounded-2xl p-5 sm:p-6"
          aria-labelledby="scheduled-workflows-title"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="scheduled-workflows-title" class="text-xl font-semibold">
                Scheduled workflows
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                Cron expressions use UTC. Discovery reads one immutable default-branch revision.
              </p>
            </div>
            <button
              id="discover-scheduled-workflows"
              phx-click="discover-scheduled-workflows"
              phx-disable-with="Loading…"
              class="btn btn-outline btn-sm"
            >Load schedules</button>
          </div>
          <p :if={@schedule_state == :not_run} class="mt-4 text-sm text-base-content/60">
            Schedules have not been loaded in this session.
          </p>
          <div :if={@schedule_state == :error} class="alert alert-error mt-4" role="alert">
            {@schedule_error}
          </div>
          <div
            :if={@schedule_head}
            id="schedule-workflow-head"
            class="mt-4 rounded-2xl bg-base-200 p-4"
          >
            <p class="text-sm font-semibold">Default branch: {@schedule_head.branch}</p>
            <code class="mt-1 block break-all text-xs">{@schedule_head.commit_sha}</code>
          </div>
          <div
            :if={@schedule_state == :ready and @scheduled_workflows == []}
            class="mt-4 rounded-2xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
          >
            No workflow at this revision declares a schedule.
          </div>
          <ul :if={@scheduled_workflows != []} class="mt-5 grid gap-4 lg:grid-cols-2">
            <li
              :for={workflow <- @scheduled_workflows}
              class="rounded-2xl border border-base-300 p-5"
            >
              <p class="font-semibold">{workflow.name}</p>
              <code class="mt-1 block break-all text-xs text-base-content/55">{workflow.path}</code>
              <div class="mt-3 flex flex-wrap items-center gap-2 text-xs">
                <span class="badge badge-success badge-sm">Active</span>
                <%= if latest = latest_scheduled_pipeline(@pipelines, workflow.name) do %>
                  <.status_badge status={latest.status} size="sm" />
                  <span class="text-base-content/50">Last run {relative_time(latest.inserted_at)}</span>
                <% else %>
                  <span class="text-base-content/50">No scheduled run retained</span>
                <% end %>
              </div>
              <ul class="mt-4 space-y-2" aria-label={"Schedules for #{workflow.name}"}>
                <li
                  :for={cron <- workflow.schedules}
                  class="rounded-xl bg-base-200 px-3 py-3"
                >
                  <p class="text-sm font-semibold">{schedule_description(cron)}</p>
                  <p class="mt-1 text-xs text-base-content/55">
                    <%= if next = next_occurrence(cron) do %>
                      Next:
                      <time
                        datetime={DateTime.to_iso8601(next)}
                        title={Calendar.strftime(next, "%Y-%m-%d %H:%M UTC")}
                      >{relative_time(next)}</time>
                    <% else %>
                      Next occurrence is outside the 32-day preview window.
                    <% end %>
                  </p>
                  <code class="mt-2 block text-xs">{cron} UTC</code>
                </li>
              </ul>
            </li>
          </ul>
        </section>
        <section
          id="previous-workflows"
          class="scroll-mt-8"
          aria-labelledby="previous-workflows-title"
        >
          <h2 id="previous-workflows-title" class="text-xl font-semibold">
            Previously run workflows
          </h2><div
            :if={@workflows == []}
            class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
          >
            No valid workflow has run yet. This reflects execution history, not every workflow currently present in the repository.
          </div><ul :if={@workflows != []} class="mt-4 space-y-3">
            <li
              :for={workflow <- @workflows}
              class="rounded-2xl border border-base-300 p-5 font-semibold"
            >
              {workflow}
            </li>
          </ul>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true

  defp repository_stat(assigns) do
    ~H"""
    <div class="surface-panel rounded-2xl p-4">
      <div class="flex items-center gap-2 text-xs font-bold uppercase tracking-wider text-base-content/40">
        <.icon name={@icon} class="size-4 text-primary" />{@label}
      </div>
      <p class="mt-3 truncate text-xl font-bold capitalize">{@value}</p>
    </div>
    """
  end

  attr :repository, :map, required: true
  attr :pipelines, :list, required: true

  defp repository_pipelines(assigns) do
    ~H"""
    <section
      id="recent-pipelines"
      class="scroll-mt-8 space-y-4"
      aria-labelledby="recent-pipelines-title"
    >
      <div class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300/70 pb-3">
        <div>
          <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-primary">
            Project activity
          </p>
          <h2 id="recent-pipelines-title" class="mt-1 text-2xl font-bold">Recent pipelines</h2>
        </div>
        <.link
          navigate={~p"/pipelines?#{%{"filters" => %{"repository" => @repository.id}}}"}
          id="all-repository-pipelines"
          class="btn btn-outline btn-sm"
        >View all</.link>
      </div>
      <.ui_state :if={@pipelines == []} kind={:empty} title="No pipeline has run yet" class="p-8">
        Push a matching commit or run a manually enabled workflow.
      </.ui_state>
      <div :if={@pipelines != []} id="repository-pipelines" class="grid gap-2">
        <article
          :for={pipeline <- Enum.take(@pipelines, 10)}
          id={"repository-pipeline-#{pipeline.id}"}
          class="surface-panel group relative grid gap-3 rounded-xl p-4 transition hover:border-primary/35 focus-within:outline-3 focus-within:outline-offset-2 focus-within:outline-primary sm:grid-cols-[minmax(0,1.3fr)_minmax(10rem,0.8fr)_auto] sm:items-center"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <.status_badge status={pipeline.status} size="sm" />
              <.link
                navigate={~p"/pipelines/#{pipeline.id}"}
                class="truncate font-bold after:absolute after:inset-0 group-hover:text-primary"
              >{pipeline.workflow_name}</.link>
            </div>
            <.link
              :if={pipeline.failure_job}
              navigate={~p"/pipelines/#{pipeline.id}/jobs/#{pipeline.failure_job.id}"}
              class="relative z-10 mt-2 inline-flex items-center gap-1 text-xs font-bold text-error hover:underline"
            ><.icon name="hero-exclamation-triangle" class="size-3.5" />Failed in {pipeline.failure_job.job_key}</.link>
          </div>
          <div class="text-xs text-base-content/50">
            <p class="truncate font-semibold text-base-content/70">
              {pipeline.source_ref || pipeline.trigger}
            </p>
            <p class="mt-1">
              <code>{String.slice(pipeline.commit_sha, 0, 8)}</code> · {pipeline.actor}
            </p>
          </div>
          <div class="flex justify-between gap-4 border-t border-base-300/60 pt-2 text-xs sm:block sm:border-0 sm:pt-0 sm:text-right">
            <span class="font-bold">{duration_label(pipeline)}</span>
            <time
              datetime={DateTime.to_iso8601(pipeline.inserted_at)}
              title={Calendar.strftime(pipeline.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
              class="block text-base-content/45"
            >{relative_time(pipeline.inserted_at)}</time>
          </div>
        </article>
      </div>
    </section>
    """
  end
end
