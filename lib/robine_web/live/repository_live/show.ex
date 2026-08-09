defmodule RobineWeb.RepositoryLive.Show do
  use RobineWeb, :live_view
  alias Robine.{Pipelines, Repositories}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         repository when not is_nil(repository) <- Enum.find(repositories, &(&1.id == id)),
         {:ok, pipelines} <-
           Pipelines.list_pipelines(%{limit: 100}, socket.assigns.execution_context) do
      repository_pipelines = Enum.filter(pipelines, &(&1.repository_id == id))

      workflows =
        repository_pipelines |> Enum.map(& &1.workflow_name) |> Enum.uniq() |> Enum.sort()

      {:ok,
       assign(socket,
         repository: repository,
         pipelines: repository_pipelines,
         workflows: workflows,
         github_preflight: :not_run,
         manual_state: :not_run,
         manual_branch_form: to_form(%{"branch" => "main"}, as: :branch_lookup),
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
        {:noreply, assign(socket, github_preflight: result)}
    end
  end

  def handle_event("check-source-control-connection", _params, socket) do
    result =
      Repositories.check_source_control_connection(
        %{repository_id: socket.assigns.repository.id},
        socket.assigns.execution_context
      )

    case result do
      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to check provider access.")}

      result ->
        {:noreply, assign(socket, github_preflight: result)}
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
             "The workflow changed or the source-control provider is unavailable. Refresh and retry.",
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
  defp provider_label(:gitlab), do: "GitLab"
  defp provider_label(:forgejo), do: "Forgejo"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <.link navigate={~p"/repositories"} class="link text-sm">← Repositories</.link><div class="mt-4 flex flex-wrap items-center gap-3">
            <h1 class="text-4xl font-bold">{@repository.full_name}</h1><span class="badge badge-success">Trusted</span>
          </div><div :if={@current_actor.role in [:administrator, :maintainer]} class="mt-5">
            <.link
              navigate={~p"/repositories/#{@repository.id}/secrets"}
              class="btn btn-outline btn-sm"
            >Manage secrets</.link>
          </div>
        </header>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">
                {provider_label(@repository.provider)} integration
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                {if @repository.provider == :github,
                  do: "Required repository permissions: Metadata read, Contents read, Checks write.",
                  else:
                    "Verify repository read access and commit-status write access at the configured provider origin."}
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
            <button
              :if={
                @repository.provider in [:gitlab, :forgejo] and
                  @current_actor.role in [:administrator, :maintainer]
              }
              id="check-source-control-connection"
              phx-click="check-source-control-connection"
              phx-disable-with="Checking…"
              class="btn btn-outline btn-sm"
            >Check connection</button>
          </div>
          <p :if={@github_preflight == :not_run} class="mt-4 text-sm text-base-content/60">
            Permission preflight has not run in this session.
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
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Run a workflow</h2>
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
              <.input field={@manual_branch_form[:branch]} label="Branch" required placeholder="main" />
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
            >
              <input type="hidden" name="workflow_path" value={workflow.path} />
              <input type="hidden" name="branch" value={@manual_head.branch} />
              <input type="hidden" name="request_id" value={@manual_request_ids[workflow.path]} />
              <h3 class="font-semibold">{workflow.name}</h3>
              <code class="mt-1 block break-all text-xs text-base-content/55">{workflow.path}</code>
              <div class="mt-5 space-y-4">
                <div :for={{id, input} <- Enum.sort(workflow.inputs)}>
                  <label class="form-control w-full">
                    <span class="label-text font-medium">
                      {id}{if input.required, do: " · required", else: ""}
                    </span>
                    <span :if={input.description} class="mb-2 text-xs text-base-content/55">
                      {input.description}
                    </span>
                    <select
                      :if={input.type in [:choice, :boolean]}
                      name={"inputs[#{id}]"}
                      required={input.required}
                      class="select select-bordered w-full"
                    >
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
                      type="text"
                      name={"inputs[#{id}]"}
                      value={input.default || ""}
                      required={input.required}
                      maxlength="1024"
                      autocomplete="off"
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
              <p class="mt-4 text-xs text-warning">Do not enter passwords or tokens.</p>
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
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Scheduled workflows</h2>
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
              <ul class="mt-4 space-y-2" aria-label={"Schedules for #{workflow.name}"}>
                <li
                  :for={cron <- workflow.schedules}
                  class="rounded-xl bg-base-200 px-3 py-2 font-mono text-sm"
                >
                  {cron} <span class="font-sans text-xs text-base-content/55">UTC</span>
                </li>
              </ul>
            </li>
          </ul>
        </section>
        <div class="grid gap-6 lg:grid-cols-2">
          <section>
            <h2 class="text-xl font-semibold">Workflows</h2><div
              :if={@workflows == []}
              class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
            >
              No valid workflow has run yet.
            </div><ul :if={@workflows != []} class="mt-4 space-y-3">
              <li
                :for={workflow <- @workflows}
                class="rounded-2xl border border-base-300 p-5 font-semibold"
              >
                {workflow}
              </li>
            </ul>
          </section><section>
            <h2 class="text-xl font-semibold">Recent pipelines</h2><div
              :if={@pipelines == []}
              class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
            >
              Waiting for a matching push or pull request.
            </div><ul class="mt-4 space-y-3">
              <li
                :for={pipeline <- Enum.take(@pipelines, 10)}
                class="rounded-2xl border border-base-300 p-5"
              >
                <div class="flex justify-between gap-4">
                  <.link
                    navigate={~p"/pipelines/#{pipeline.id}"}
                    class="font-semibold link link-hover"
                  >{pipeline.workflow_name}</.link><.status_badge status={pipeline.status} />
                </div><code class="mt-2 block text-xs">{String.slice(pipeline.commit_sha, 0, 12)}</code>
              </li>
            </ul>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
