defmodule Robine.Adapters.CLI do
  @moduledoc "Command-line delivery adapter for local Robine workflows."

  alias Robine.Execution
  alias Robine.Adapters.CLI.LocalSecretFile
  alias Robine.Adapters.CLI.LocalSourceSnapshot
  alias Robine.Adapters.CLI.NativeRuntime
  alias Robine.Runtime.Dependencies, as: RuntimeDependencies
  alias Robine.Workflows

  @workflow_path ".robine-ci/workflows/ci.yml"
  @version Mix.Project.config()[:version]

  @spec main([String.t()]) :: no_return()
  def main(arguments) do
    {status, output} =
      case NativeRuntime.prepare() do
        :ok -> run(arguments, File.cwd!())
        {:error, reason} -> {3, "CLI native runtime is unavailable: #{inspect(reason)}"}
      end

    IO.puts(output)
    System.halt(status)
  end

  @spec run([String.t()], String.t()) :: {non_neg_integer(), String.t()}
  def run(["version"], _directory), do: {0, "robine #{@version}"}
  def run(["--version"], directory), do: run(["version"], directory)

  def run(["validate" | arguments], directory) do
    {options, paths, invalid} =
      OptionParser.parse(arguments, strict: [format: :string], aliases: [f: :format])

    cond do
      invalid != [] ->
        usage_error("unknown option #{elem(hd(invalid), 0)}")

      options[:format] not in [nil, "human", "json"] ->
        usage_error("format must be human or json")

      length(paths) > 1 ->
        usage_error("validate accepts at most one path")

      true ->
        validate(
          Path.expand(List.first(paths) || @workflow_path, directory),
          directory,
          options[:format] || "human"
        )
    end
  end

  def run(["init" | arguments], directory) do
    {options, paths, invalid} =
      OptionParser.parse(arguments, strict: [yes: :boolean, force: :boolean])

    cond do
      invalid != [] -> usage_error("unknown option #{elem(hd(invalid), 0)}")
      paths != [] -> usage_error("init does not accept positional arguments")
      true -> initialize(directory, options)
    end
  end

  def run(["run" | arguments], directory) do
    {options, jobs, invalid} =
      OptionParser.parse(arguments,
        strict: [
          workflow: :string,
          no_deps: :boolean,
          step: :string,
          env_file: :string,
          input: [:string, :keep]
        ],
        aliases: [w: :workflow]
      )

    cond do
      invalid != [] -> usage_error("unknown option #{elem(hd(invalid), 0)}")
      length(jobs) > 1 -> usage_error("run accepts at most one job ID")
      options[:step] && jobs == [] -> usage_error("--step requires a job ID")
      true -> execute_local(directory, List.first(jobs), options)
    end
  end

  def run([], _directory), do: usage_error("a command is required")
  def run([command | _], _directory), do: usage_error("unknown command #{command}")

  defp validate(path, directory, format) do
    case resolve_local_workflow(path, directory) do
      {:ok, validated} ->
        render_validation({:ok, validated}, format)

      {:error, diagnostics} when is_list(diagnostics) ->
        render_validation({:error, diagnostics}, format)

      {:error, :unsafe_workflow_source} ->
        {3, "Cannot read #{path}: workflow sources must be regular files, not symbolic links."}

      {:error, reason} ->
        {3, "Cannot read #{path}: #{:file.format_error(reason)}\nCreate it with `robine init`."}
    end
  end

  defp render_validation({:ok, validated}, "json") do
    {0,
     Jason.encode!(%{
       valid: true,
       path: validated.path,
       jobs: validated.workflow.order,
       warnings: Enum.map(validated.warnings, &diagnostic/1)
     })}
  end

  defp render_validation({:error, diagnostics}, "json") do
    {2, Jason.encode!(%{valid: false, diagnostics: Enum.map(diagnostics, &diagnostic/1)})}
  end

  defp render_validation({:ok, validated}, "human") do
    suffix =
      if validated.warnings == [], do: "", else: "\n" <> render_diagnostics(validated.warnings)

    jobs = Enum.map_join(validated.workflow.order, "\n", &"  - #{&1}")

    {0,
     "Valid workflow: #{validated.path}\nExpanded jobs (#{length(validated.workflow.order)}):\n#{jobs}#{suffix}"}
  end

  defp render_validation({:error, diagnostics}, "human") do
    {2,
     "Invalid workflow\n" <>
       render_diagnostics(diagnostics) <> "\nFix these errors and run `robine validate` again."}
  end

  defp initialize(directory, options) do
    path = Path.join(directory, @workflow_path)
    source = template(detect_project(directory))

    cond do
      File.exists?(path) and options[:force] != true ->
        {4, "Refusing to overwrite #{path}. Review it or pass --force explicitly."}

      options[:yes] != true ->
        {0, "Would create #{path}:\n\n#{source}\nRun `robine init --yes` to write it."}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(path)), :ok <- File.write(path, source) do
          {0, "Created #{path}\nNext: run `robine validate`."}
        else
          {:error, reason} -> {3, "Cannot create #{path}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp execute_local(directory, job_id, options) do
    path = Path.expand(options[:workflow] || @workflow_path, directory)

    with {:ok, inputs} <- parse_manual_inputs(Keyword.get_values(options, :input)),
         {:ok, local_secrets} <- load_local_secrets(options[:env_file], directory),
         {:ok, validated} <- resolve_local_workflow(path, directory),
         {:ok, validated} <- prepare_manual_workflow(validated, inputs),
         {:ok, plan} <-
           Execution.build_local_plan(
             %{
               validated_workflow: validated,
               source_path: directory,
               job_id: job_id,
               no_deps: options[:no_deps] == true,
               step: options[:step],
               local_secret_file: not is_nil(options[:env_file]),
               local_secrets: local_secrets
             },
             context()
           ) do
      execute_plan(plan, context())
    else
      {:error, diagnostics} when is_list(diagnostics) ->
        render_validation({:error, diagnostics}, "human")

      {:error, :enoent} ->
        {3, "Cannot read #{path}: file does not exist\nCreate it with `robine init`."}

      {:error, :unsafe_workflow_source} ->
        {3, "Cannot read #{path}: workflow sources must be regular files, not symbolic links."}

      {:error, {:unknown_job, job, choices}} ->
        {2, "Unknown job #{job}. Available jobs: #{Enum.join(choices, ", ")}."}

      {:error, {:unknown_step, step}} ->
        {2, "Unknown step #{step}. Use a stable step name or one-based index."}

      {:error, {:local_secrets_missing, names}} ->
        {2, "Local secret file is missing required names: #{Enum.join(names, ", ")}."}

      {:error, reason}
      when reason in [
             :git_repository_required,
             :git_unavailable,
             :local_secret_file_outside_repository,
             :local_secret_file_not_found,
             :unsafe_local_secret_file,
             :local_secret_file_not_ignored,
             :git_ignore_check_failed,
             :local_secret_file_too_large
           ] ->
        {2, local_secret_error(reason)}

      {:error, {:invalid_local_secret_file, line}} ->
        {2, "Invalid local secret file syntax at #{inspect(line)}; use one NAME=VALUE per line."}

      {:error, {:invalid_manual_input, value}} ->
        {2, "Invalid --input #{inspect(value)}; use NAME=VALUE."}

      {:error, {:duplicate_manual_input, name}} ->
        {2, "Manual input #{name} was supplied more than once."}

      {:error, :manual_trigger_not_declared} ->
        {2, "--input requires on.workflow_dispatch.inputs in the workflow."}

      {:error, {:manual_inputs_undeclared, names}} ->
        {2, "Undeclared manual inputs: #{Enum.join(names, ", ")}."}

      {:error, {:manual_input, name, reason}} ->
        {2, "Manual input #{name} is #{manual_input_error(reason)}."}

      {:error, {:invalid_secret_value, name, reason}} ->
        {2, "Local secret #{name} violates the masking policy: #{reason}."}

      {:error, reason} ->
        {3, "Cannot prepare local execution: #{inspect(reason)}"}
    end
  end

  defp load_local_secrets(nil, _directory), do: {:ok, %{}}
  defp load_local_secrets(path, directory), do: LocalSecretFile.load(path, directory)

  defp resolve_local_workflow(path, directory) do
    workflow_root = Path.expand(".robine-ci/workflows", directory)

    if inside_directory?(path, workflow_root) do
      with :ok <- regular_workflow_file(path),
           {:ok, sources} <- local_workflow_sources(workflow_root, directory) do
        entry_path = repository_path(path, directory)
        Workflows.resolve(%{entry_path: entry_path, sources: sources}, context())
      end
    else
      with {:ok, source} <- File.read(path) do
        Workflows.validate(%{source: source, path: path}, context())
      end
    end
  end

  defp local_workflow_sources(workflow_root, directory) do
    workflow_root
    |> Path.join("**/*.yml")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, sources} ->
      case regular_workflow_file(path) do
        :ok ->
          case File.read(path) do
            {:ok, source} ->
              {:cont, {:ok, Map.put(sources, repository_path(path, directory), source)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, :unsafe_workflow_source} ->
          {:cont, {:ok, sources}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp regular_workflow_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _other} -> {:error, :unsafe_workflow_source}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inside_directory?(path, directory) do
    expanded = Path.expand(path)
    expanded == directory or String.starts_with?(expanded, directory <> "/")
  end

  defp repository_path(path, directory) do
    path
    |> Path.expand()
    |> Path.relative_to(Path.expand(directory))
    |> String.replace("\\", "/")
  end

  defp parse_manual_inputs(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, inputs} ->
      case String.split(value, "=", parts: 2) do
        [name, submitted] when name != "" ->
          if Map.has_key?(inputs, name),
            do: {:halt, {:error, {:duplicate_manual_input, name}}},
            else: {:cont, {:ok, Map.put(inputs, name, submitted)}}

        _invalid ->
          {:halt, {:error, {:invalid_manual_input, value}}}
      end
    end)
  end

  defp prepare_manual_workflow(validated, inputs) when map_size(inputs) == 0,
    do: {:ok, validated}

  defp prepare_manual_workflow(validated, inputs) do
    with {:ok, prepared} <-
           Workflows.prepare_manual_run(%{validated_workflow: validated, inputs: inputs}) do
      {:ok, %{validated | workflow: prepared.workflow}}
    end
  end

  defp manual_input_error(:required), do: "required"
  defp manual_input_error(:invalid_choice), do: "not an allowed choice"
  defp manual_input_error(:invalid_boolean), do: "not a boolean"
  defp manual_input_error(:invalid_string), do: "not a valid bounded string"
  defp manual_input_error(reason), do: inspect(reason)

  defp local_secret_error(:git_repository_required),
    do: "--env-file requires a Git repository so ignore status can be proven."

  defp local_secret_error(:git_unavailable), do: "Git is required to verify --env-file."

  defp local_secret_error(:local_secret_file_outside_repository),
    do: "--env-file must be inside the repository."

  defp local_secret_error(:local_secret_file_not_found), do: "Local secret file does not exist."

  defp local_secret_error(:unsafe_local_secret_file),
    do: "Local secret file must be a regular file, not a link or special file."

  defp local_secret_error(:local_secret_file_not_ignored),
    do: "Refusing local secret file because Git does not ignore it; add it to .gitignore first."

  defp local_secret_error(:git_ignore_check_failed),
    do: "Git could not prove that the local secret file is ignored."

  defp local_secret_error(:local_secret_file_too_large),
    do: "Local secret file exceeds the 1 MiB safety limit."

  defp execute_plan(plan, context) do
    source_path = plan.specifications |> List.first() |> Map.fetch!(:source_path)

    case LocalSourceSnapshot.create(source_path) do
      {:ok, snapshot} ->
        try do
          execute_snapshot(plan, context, snapshot)
        after
          LocalSourceSnapshot.cleanup(snapshot)
          Process.delete({__MODULE__, :local_state})
        end

      {:error, reason} ->
        {3, "Cannot prepare a safe local source snapshot: #{inspect(reason)}"}
    end
  end

  defp execute_snapshot(plan, context, snapshot) do
    local_state = %{source_path: snapshot.source_root, artifacts: %{}}
    put_local_state(local_state)

    header = [
      "Workflow revision: #{plan.workflow_revision}",
      "Working directory: /workspace (copied from #{snapshot.source_root})",
      "CI-only inputs omitted: #{Enum.join(plan.ci_only_inputs_omitted, ", ")}"
    ]

    header =
      if plan.dependencies_omitted,
        do: header ++ ["Warning: required job dependencies were explicitly omitted."],
        else: header

    header =
      if plan.local_secret_count > 0,
        do: header ++ ["Local secrets: #{plan.local_secret_count} declared values injected."],
        else: header

    specifications = Enum.map(plan.specifications, &%{&1 | source_path: snapshot.path})

    Enum.reduce_while(specifications, {0, header, local_state, %{}}, fn specification,
                                                                        {exit_status, lines,
                                                                         state, job_statuses} ->
      job_id = specification.metadata["job_id"]

      case local_job_condition(specification, job_statuses, plan.dependencies_omitted) do
        :run ->
          run_local_job(
            specification,
            context,
            job_id,
            exit_status,
            lines,
            state,
            job_statuses
          )

        :skip ->
          condition = specification.metadata["condition"]
          line = "[skipped] #{job_id} (if: #{condition} did not match dependency outcomes)"
          {:cont, {exit_status, lines ++ [line], state, Map.put(job_statuses, job_id, :skipped)}}

        :wait ->
          {:halt,
           {3,
            lines ++
              ["Cannot evaluate local condition for #{job_id}: dependencies are incomplete."],
            state, job_statuses}}
      end
    end)
    |> then(fn {status, lines, _state, _job_statuses} ->
      {status, Enum.join(lines, "\n")}
    end)
  end

  defp local_job_condition(specification, job_statuses, dependencies_omitted) do
    missing_status = if dependencies_omitted, do: :succeeded, else: nil

    dependency_statuses =
      Enum.map(specification.metadata["needs"], &Map.get(job_statuses, &1, missing_status))

    {:ok, outcome} =
      Execution.evaluate_job_condition(%{
        condition: specification.metadata["condition"],
        dependency_statuses: dependency_statuses
      })

    outcome
  end

  defp run_local_job(
         specification,
         context,
         job_id,
         exit_status,
         lines,
         state,
         job_statuses
       ) do
    lines = lines ++ ["Running #{job_id} with #{specification.image}"]
    handler = fn event -> local_builtin(event, job_id, local_state()) end
    put_local_service_events([])

    output_handler = fn event ->
      record_local_service_event(event)
      :ok
    end

    case Execution.run_job(
           %{specification: specification, on_builtin: handler, on_output: output_handler},
           context
         ) do
      {:ok, %{status: :succeeded, steps: steps}} ->
        {:cont,
         {exit_status, lines ++ local_service_events() ++ render_steps(steps), local_state(),
          Map.put(job_statuses, job_id, :succeeded)}}

      {:ok, %{status: :failed, reason: reason, steps: steps}} ->
        {:cont,
         {5, lines ++ local_service_events() ++ render_steps(steps) ++ ["Job failed: #{reason}"],
          local_state(), Map.put(job_statuses, job_id, :failed)}}

      {:ok, %{status: :cancelled, steps: steps}} ->
        {:halt,
         {5, lines ++ local_service_events() ++ render_steps(steps) ++ ["Job cancelled"], state,
          Map.put(job_statuses, job_id, :cancelled)}}

      {:error, reason} ->
        {:halt,
         {3,
          lines ++
            local_service_events() ++
            [
              "Runner infrastructure error: #{inspect(reason)}\nCheck that Docker is installed and running."
            ], state, job_statuses}}
    end
  end

  defp local_builtin(
         %{phase: :restore, builtin: "cache/restore", options: %{"key" => key}},
         _job,
         state
       ) do
    case File.read(local_cache_path(state.source_path, key)) do
      {:ok, content} -> {:ok, %{content: content}}
      {:error, :enoent} -> {:ok, :miss}
      {:error, reason} -> {:error, {:local_cache_read, reason}}
    end
  end

  defp local_builtin(
         %{phase: :publish, builtin: "cache/save", options: %{"key" => key}, content: content},
         _job,
         state
       ) do
    target = local_cache_path(state.source_path, key)
    temporary = target <> ".#{Ecto.UUID.generate()}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.rename(temporary, target) do
      {:ok, %{size: byte_size(content)}}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:local_cache_write, reason}}
    end
  end

  defp local_builtin(
         %{
           phase: :publish,
           builtin: "artifacts/upload",
           options: %{"name" => name},
           content: content
         },
         job,
         state
       ) do
    put_local_state(%{state | artifacts: Map.put(state.artifacts, {job, name}, content)})
    {:ok, %{size: byte_size(content)}}
  end

  defp local_builtin(
         %{
           phase: :restore,
           builtin: "artifacts/download",
           options: %{"name" => name, "from" => from}
         },
         _job,
         state
       ) do
    case Map.fetch(state.artifacts, {from, name}) do
      {:ok, content} -> {:ok, %{content: content}}
      :error -> {:error, {:local_artifact_missing, from, name}}
    end
  end

  defp local_builtin(event, _job, _state),
    do: {:error, {:unsupported_local_builtin, event.builtin}}

  defp local_cache_path(source_path, key) do
    repository =
      :crypto.hash(:sha256, Path.expand(source_path)) |> Base.url_encode64(padding: false)

    cache_key = :crypto.hash(:sha256, key) |> Base.url_encode64(padding: false)

    Path.join([
      to_string(:filename.basedir(:user_cache, "robine")),
      repository,
      cache_key <> ".tar.gz"
    ])
  end

  defp put_local_state(state), do: Process.put({__MODULE__, :local_state}, state)
  defp local_state, do: Process.get({__MODULE__, :local_state})
  defp put_local_service_events(events), do: Process.put({__MODULE__, :service_events}, events)

  defp record_local_service_event(%{
         phase: :service_preparation,
         step_name: name,
         status: status,
         content: content
       }) do
    line = "[#{status}] #{name}: #{String.trim(content)}"
    put_local_service_events([line | local_service_events()])
  end

  defp record_local_service_event(_event), do: :ok

  defp local_service_events do
    Process.get({__MODULE__, :service_events}, []) |> Enum.reverse()
  end

  defp render_steps(steps) do
    Enum.flat_map(steps, fn step ->
      [
        "[#{step.status}] #{step.name} (#{step.duration_ms} ms)",
        String.trim_trailing(step.output)
      ]
    end)
  end

  defp detect_project(directory) do
    cond do
      File.exists?(Path.join(directory, "mix.exs")) -> :elixir
      File.exists?(Path.join(directory, "package.json")) -> :node
      true -> :generic
    end
  end

  defp template(:elixir),
    do: template("hexpm/elixir:1.18.4-erlang-27.3", "mix deps.get\nmix test")

  defp template(:node), do: template("node:24-alpine", "npm ci\nnpm test")
  defp template(:generic), do: template("alpine:3.22", "echo 'Configure your CI commands'")

  defp template(image, commands) do
    steps =
      commands
      |> String.split("\n")
      |> Enum.map_join("\n", &"      - run: #{&1}")

    """
    version: 1
    name: CI
    on:
      push:
        branches: [main]
      pull_request: {}
    jobs:
      test:
        image: #{image}
        steps:
          - uses: checkout
    #{steps}
    """
  end

  defp context, do: RuntimeDependencies.local_context()

  defp diagnostic(value) do
    %{
      code: value.code,
      message: value.message,
      path: value.path,
      line: value.line,
      column: value.column,
      source_path: value.source_path,
      severity: value.severity
    }
  end

  defp render_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "\n", fn value ->
      path = if value.path == [], do: "$", else: Enum.join(value.path, ".")
      source = if value.source_path, do: "#{value.source_path}:", else: ""
      "#{value.severity} [#{value.code}] #{source}#{path}: #{value.message}"
    end)
  end

  defp usage_error(message) do
    {64,
     "#{message}\nUsage: robine init [--yes] [--force] | validate [path] [--format human|json] | run [job-id] [--workflow path] [--input NAME=VALUE] [--no-deps] [--step name-or-index] [--env-file ignored-path] | version"}
  end
end
