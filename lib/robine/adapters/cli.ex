defmodule Robine.Adapters.CLI do
  @moduledoc "Command-line delivery adapter for local Robine workflows."

  alias Robine.ExecutionContext
  alias Robine.Execution
  alias Robine.Execution.Dependencies, as: ExecutionDependencies
  alias Robine.Workflows
  alias Robine.Workflows.Dependencies

  @workflow_path ".robine-ci/workflows/ci.yml"
  @version Mix.Project.config()[:version]

  @spec main([String.t()]) :: no_return()
  def main(arguments) do
    {status, output} = run(arguments, File.cwd!())
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
        strict: [workflow: :string, no_deps: :boolean, step: :string],
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

  defp validate(path, format) do
    case File.read(path) do
      {:ok, source} ->
        render_validation(Workflows.validate(%{source: source, path: path}, context()), format)

      {:error, reason} ->
        {3, "Cannot read #{path}: #{:file.format_error(reason)}\nCreate it with `robine init`."}
    end
  end

  defp render_validation({:ok, validated}, "json") do
    {0,
     Jason.encode!(%{
       valid: true,
       path: validated.path,
       warnings: Enum.map(validated.warnings, &diagnostic/1)
     })}
  end

  defp render_validation({:error, diagnostics}, "json") do
    {2, Jason.encode!(%{valid: false, diagnostics: Enum.map(diagnostics, &diagnostic/1)})}
  end

  defp render_validation({:ok, validated}, "human") do
    suffix =
      if validated.warnings == [], do: "", else: "\n" <> render_diagnostics(validated.warnings)

    {0, "Valid workflow: #{validated.path}#{suffix}"}
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

    with {:ok, source} <- File.read(path),
         {:ok, validated} <- Workflows.validate(%{source: source, path: path}, context()),
         {:ok, plan} <-
           Execution.build_local_plan(
             %{
               validated_workflow: validated,
               source_path: directory,
               job_id: job_id,
               no_deps: options[:no_deps] == true,
               step: options[:step]
             },
             context()
           ) do
      execute_plan(plan, context())
    else
      {:error, diagnostics} when is_list(diagnostics) ->
        render_validation({:error, diagnostics}, "human")

      {:error, :enoent} ->
        {3, "Cannot read #{path}: file does not exist\nCreate it with `robine init`."}

      {:error, {:unknown_job, job, choices}} ->
        {2, "Unknown job #{job}. Available jobs: #{Enum.join(choices, ", ")}."}

      {:error, {:unknown_step, step}} ->
        {2, "Unknown step #{step}. Use a stable step name or one-based index."}

      {:error, reason} ->
        {3, "Cannot prepare local execution: #{inspect(reason)}"}
    end
  end

  defp execute_plan(plan, context) do
    source_path = plan.specifications |> List.first() |> Map.fetch!(:source_path)
    local_state = %{source_path: source_path, artifacts: %{}}
    put_local_state(local_state)

    header = [
      "Workflow revision: #{plan.workflow_revision}",
      "Working directory: /workspace (copied from #{source_path})",
      "CI-only inputs omitted: #{Enum.join(plan.ci_only_inputs_omitted, ", ")}"
    ]

    header =
      if plan.dependencies_omitted,
        do: header ++ ["Warning: required job dependencies were explicitly omitted."],
        else: header

    Enum.reduce_while(plan.specifications, {0, header, local_state}, fn specification,
                                                                        {_status, lines, state} ->
      lines = lines ++ ["Running #{specification.metadata["job_id"]} with #{specification.image}"]

      handler = fn event ->
        local_builtin(event, specification.metadata["job_id"], local_state())
      end

      case Execution.run_job(%{specification: specification, on_builtin: handler}, context) do
        {:ok, %{status: :succeeded, steps: steps}} ->
          {:cont, {0, lines ++ render_steps(steps), local_state()}}

        {:ok, %{status: :failed, reason: reason, steps: steps}} ->
          {:halt, {5, lines ++ render_steps(steps) ++ ["Job failed: #{reason}"], state}}

        {:error, reason} ->
          {:halt,
           {3,
            lines ++
              [
                "Runner infrastructure error: #{inspect(reason)}\nCheck that Docker is installed and running."
              ], state}}
      end
    end)
    |> then(fn {status, lines, _state} ->
      Process.delete({__MODULE__, :local_state})
      {status, Enum.join(lines, "\n")}
    end)
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

  defp context do
    ExecutionContext.new(%{id: "cli", role: :maintainer}, "cli", %{
      workflows: %Dependencies{decoder: Robine.Adapters.Workflow.YamlDecoder},
      execution: %ExecutionDependencies{runner: Robine.Adapters.Execution.DockerRunner}
    })
  end

  defp diagnostic(value) do
    %{
      code: value.code,
      message: value.message,
      path: value.path,
      line: value.line,
      column: value.column,
      severity: value.severity
    }
  end

  defp render_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "\n", fn value ->
      path = if value.path == [], do: "$", else: Enum.join(value.path, ".")
      "#{value.severity} [#{value.code}] #{path}: #{value.message}"
    end)
  end

  defp usage_error(message) do
    {64,
     "#{message}\nUsage: robine init [--yes] [--force] | validate [path] [--format human|json] | run [job-id] [--workflow path] [--no-deps] [--step name-or-index] | version"}
  end
end
