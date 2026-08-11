defmodule Robine.Workflows.Domain.Validator do
  @moduledoc "Pure structural and semantic validation for workflow schema version 1."

  alias Robine.Workflows.Domain.{
    CronExpression,
    Diagnostic,
    Job,
    ManualInput,
    Schedule,
    Service,
    Step,
    Workflow
  }

  @root_keys ~w(version name on jobs)
  @job_keys ~w(image needs steps timeout shell env secrets services runs-on if strategy)
  @strategy_keys ~w(matrix)
  @service_keys ~w(image user env secret-env command readiness privileged)
  @readiness_keys ~w(tcp timeout)
  @step_keys ~w(name run uses with if)
  @dispatch_keys ~w(inputs)
  @schedule_keys ~w(cron)
  @input_keys ~w(description type required default options)
  @builtins ~w(checkout cache/restore cache/save artifacts/upload artifacts/download)
  @job_id ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @runner_label ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]*\z/
  @container_user ~r/\A[a-zA-Z0-9_.-]+(?::[a-zA-Z0-9_.-]+)?\z/
  @build_environment_names ~w(
    ROBINE_BUILD_COMMIT_SHA
    ROBINE_BUILD_REF_NAME
    ROBINE_BUILD_REF_TYPE
    ROBINE_BUILD_TIMESTAMP
    ROBINE_BUILD_PIPELINE_ID
    ROBINE_BUILD_TRIGGER
  )

  @default_limits [
    max_jobs: 64,
    max_steps_per_job: 128,
    max_total_steps: 512,
    max_graph_depth: 16
  ]

  @spec validate(map(), keyword()) ::
          {:ok, Workflow.t(), [Diagnostic.t()]} | {:error, [Diagnostic.t()]}
  def validate(document, limits \\ @default_limits)

  def validate(document, limits) when is_map(document) do
    errors = unknown_keys(document, @root_keys, [])

    with [] <- errors,
         {:ok, version} <- exact_version(document),
         {:ok, name} <- nonempty_string(document, "name", ["name"]),
         {:ok, triggers} <- triggers(document),
         {:ok, base_jobs, warnings} <- jobs(document, limits),
         :ok <- build_environment(base_jobs),
         :ok <- trigger_input_environment(triggers, base_jobs),
         {:ok, jobs} <- expand_matrices(base_jobs, limits),
         {:ok, order} <- topological_order(jobs),
         :ok <- graph_limits(jobs, order, limits) do
      {:ok, %Workflow{version: version, name: name, triggers: triggers, jobs: jobs, order: order},
       warnings}
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, %Diagnostic{} = error} -> {:error, [error]}
    end
  end

  def validate(_document, _limits),
    do: {:error, [Diagnostic.error("workflow.type", "workflow must be a map", [])]}

  defp exact_version(%{"version" => 1}), do: {:ok, 1}

  defp exact_version(document) do
    {:error,
     Diagnostic.error(
       "workflow.version",
       "version must be 1, got #{inspect(Map.get(document, "version"))}",
       ["version"]
     )}
  end

  defp triggers(%{"on" => triggers}) when is_map(triggers) and map_size(triggers) > 0 do
    supported = ~w(push pull_request workflow_dispatch workflow_call schedule)
    errors = unknown_keys(triggers, supported, ["on"])

    with [] <- errors,
         {:ok, dispatch} <- manual_dispatch(Map.get(triggers, "workflow_dispatch")),
         {:ok, call} <- workflow_call(Map.get(triggers, "workflow_call")),
         {:ok, schedules} <- schedules(Map.get(triggers, "schedule")) do
      normalized = maybe_put_trigger(triggers, "workflow_dispatch", dispatch)
      normalized = maybe_put_trigger(normalized, "workflow_call", call)
      normalized = maybe_put_trigger(normalized, "schedule", schedules)

      {:ok, normalized}
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, errors} -> {:error, List.wrap(errors)}
    end
  end

  defp triggers(_document) do
    {:error, Diagnostic.error("workflow.triggers", "on must contain a trigger", ["on"])}
  end

  defp maybe_put_trigger(triggers, name, normalized) do
    if Map.has_key?(triggers, name), do: Map.put(triggers, name, normalized), else: triggers
  end

  defp schedules(nil), do: {:ok, []}

  defp schedules(schedules) when is_list(schedules) and length(schedules) in 1..8 do
    {normalized, errors} =
      schedules
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {schedule, index}, {normalized, errors} ->
        case schedule(schedule, index) do
          {:ok, value} -> {normalized ++ [value], errors}
          {:error, value} -> {normalized, errors ++ List.wrap(value)}
        end
      end)

    duplicate_errors =
      normalized
      |> Enum.group_by(& &1.cron)
      |> Enum.filter(fn {_cron, entries} -> length(entries) > 1 end)
      |> Enum.map(fn {cron, _entries} ->
        Diagnostic.error(
          "schedule.duplicate",
          "duplicate cron expression #{inspect(cron)}",
          ["on", "schedule"]
        )
      end)

    if errors == [] and duplicate_errors == [],
      do: {:ok, normalized},
      else: {:error, errors ++ duplicate_errors}
  end

  defp schedules(_schedules) do
    {:error,
     Diagnostic.error(
       "schedule.type",
       "schedule must be a list of one to eight entries",
       ["on", "schedule"]
     )}
  end

  defp schedule(schedule, index) when is_map(schedule) do
    path = ["on", "schedule", index]

    with [] <- unknown_keys(schedule, @schedule_keys, path),
         cron when is_binary(cron) <- Map.get(schedule, "cron"),
         {:ok, expression} <- CronExpression.parse(cron) do
      {:ok, %Schedule{cron: expression.raw, expression: expression}}
    else
      errors when is_list(errors) ->
        {:error, errors}

      _invalid ->
        {:error,
         Diagnostic.error(
           "schedule.cron",
           "cron must be a valid bounded five-field UTC expression",
           path ++ ["cron"]
         )}
    end
  end

  defp schedule(_schedule, index) do
    {:error,
     Diagnostic.error(
       "schedule.entry",
       "schedule entry must be a map",
       ["on", "schedule", index]
     )}
  end

  defp manual_dispatch(nil), do: {:ok, %{"inputs" => %{}}}

  defp manual_dispatch(dispatch) when is_map(dispatch) do
    with [] <- unknown_keys(dispatch, @dispatch_keys, ["on", "workflow_dispatch"]),
         {:ok, inputs} <-
           normalize_input_definitions(Map.get(dispatch, "inputs", %{}), [
             "on",
             "workflow_dispatch",
             "inputs"
           ]) do
      {:ok, %{"inputs" => inputs}}
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, errors} -> {:error, List.wrap(errors)}
    end
  end

  defp manual_dispatch(_dispatch) do
    {:error,
     Diagnostic.error(
       "workflow.manual_trigger",
       "workflow_dispatch must be a map",
       ["on", "workflow_dispatch"]
     )}
  end

  defp workflow_call(nil), do: {:ok, %{"inputs" => %{}}}

  defp workflow_call(call) when is_map(call) do
    with [] <- unknown_keys(call, @dispatch_keys, ["on", "workflow_call"]),
         {:ok, inputs} <-
           normalize_input_definitions(Map.get(call, "inputs", %{}), [
             "on",
             "workflow_call",
             "inputs"
           ]) do
      {:ok, %{"inputs" => inputs}}
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, errors} -> {:error, List.wrap(errors)}
    end
  end

  defp workflow_call(_call) do
    {:error,
     Diagnostic.error(
       "workflow.call_trigger",
       "workflow_call must be a map",
       ["on", "workflow_call"]
     )}
  end

  @doc false
  @spec normalize_input_definitions(term(), list()) ::
          {:ok, %{optional(String.t()) => ManualInput.t()}} | {:error, [Diagnostic.t()]}
  def normalize_input_definitions(inputs, base_path)
      when is_map(inputs) and map_size(inputs) <= 16 do
    {normalized, errors} =
      inputs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, []}, fn {id, definition}, {normalized, errors} ->
        case input_definition(id, definition, base_path) do
          {:ok, input} -> {Map.put(normalized, id, input), errors}
          {:error, input_errors} -> {normalized, errors ++ List.wrap(input_errors)}
        end
      end)

    if errors == [], do: {:ok, normalized}, else: {:error, errors}
  end

  def normalize_input_definitions(_inputs, base_path) do
    {:error,
     Diagnostic.error(
       "workflow.manual_inputs",
       "manual inputs must be a map of at most 16 definitions",
       base_path
     )}
  end

  defp input_definition(id, definition, base_path) when is_binary(id) and is_map(definition) do
    path = base_path ++ [id]

    errors =
      unknown_keys(definition, @input_keys, path) ++
        if(Regex.match?(~r/\A[a-z][a-z0-9_]{0,30}\z/, id),
          do: [],
          else: [Diagnostic.error("manual_input.id", "invalid manual input identifier", path)]
        )

    with [] <- errors,
         {:ok, description} <- manual_description(Map.get(definition, "description"), path),
         {:ok, type} <- manual_input_type(Map.get(definition, "type", "string"), path),
         {:ok, required} <- manual_required(Map.get(definition, "required", false), path),
         {:ok, options} <- manual_options(type, Map.get(definition, "options"), path),
         {:ok, default} <- manual_default(type, Map.get(definition, "default"), options, path) do
      {:ok,
       %ManualInput{
         id: id,
         description: description,
         type: type,
         required: required,
         default: default,
         options: options
       }}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp input_definition(id, _definition, base_path) do
    {:error,
     Diagnostic.error(
       "manual_input.type",
       "manual input definition must be a map",
       base_path ++ [to_string(id)]
     )}
  end

  defp manual_description(nil, _path), do: {:ok, nil}

  defp manual_description(value, _path)
       when is_binary(value) and byte_size(value) <= 256,
       do: {:ok, value}

  defp manual_description(_value, path),
    do:
      {:error,
       Diagnostic.error(
         "manual_input.description",
         "description must be at most 256 bytes",
         path ++ ["description"]
       )}

  defp manual_input_type("string", _path), do: {:ok, :string}
  defp manual_input_type("choice", _path), do: {:ok, :choice}
  defp manual_input_type("boolean", _path), do: {:ok, :boolean}

  defp manual_input_type(_type, path),
    do:
      {:error,
       Diagnostic.error(
         "manual_input.type",
         "type must be string, choice, or boolean",
         path ++ ["type"]
       )}

  defp manual_required(value, _path) when is_boolean(value), do: {:ok, value}

  defp manual_required(_value, path),
    do:
      {:error,
       Diagnostic.error(
         "manual_input.required",
         "required must be boolean",
         path ++ ["required"]
       )}

  defp manual_options(:choice, options, path)
       when is_list(options) and length(options) in 2..32 do
    if Enum.all?(options, &manual_string?/1) and length(Enum.uniq(options)) == length(options),
      do: {:ok, options},
      else:
        {:error,
         Diagnostic.error(
           "manual_input.options",
           "choice options must be 2 to 32 unique bounded strings",
           path ++ ["options"]
         )}
  end

  defp manual_options(:choice, _options, path),
    do:
      {:error,
       Diagnostic.error(
         "manual_input.options",
         "choice inputs require 2 to 32 options",
         path ++ ["options"]
       )}

  defp manual_options(_type, nil, _path), do: {:ok, nil}

  defp manual_options(_type, _options, path),
    do:
      {:error,
       Diagnostic.error(
         "manual_input.options",
         "only choice inputs accept options",
         path ++ ["options"]
       )}

  defp manual_default(_type, nil, _options, _path), do: {:ok, nil}

  defp manual_default(:boolean, value, _options, _path) when is_boolean(value),
    do: {:ok, to_string(value)}

  defp manual_default(:choice, value, options, path) do
    if value in options,
      do: {:ok, value},
      else:
        {:error,
         Diagnostic.error(
           "manual_input.default",
           "default does not match the declared input type",
           path ++ ["default"]
         )}
  end

  defp manual_default(:string, value, _options, path) when is_binary(value) do
    if manual_string?(value),
      do: {:ok, value},
      else:
        {:error,
         Diagnostic.error(
           "manual_input.default",
           "default does not match the declared input type",
           path ++ ["default"]
         )}
  end

  defp manual_default(_type, _value, _options, path),
    do:
      {:error,
       Diagnostic.error(
         "manual_input.default",
         "default does not match the declared input type",
         path ++ ["default"]
       )}

  defp manual_string?(value) when is_binary(value) and byte_size(value) <= 1_024,
    do: String.valid?(value) and not String.contains?(value, ["\n", "\r", <<0>>])

  defp manual_string?(_value), do: false

  defp trigger_input_environment(triggers, jobs) do
    with :ok <-
           input_environment(
             get_in(triggers, ["workflow_dispatch", "inputs"]) || %{},
             jobs,
             "ROBINE_INPUT_",
             "manual_input.env_collision",
             "manual input"
           ),
         :ok <-
           input_environment(
             get_in(triggers, ["workflow_call", "inputs"]) || %{},
             jobs,
             "ROBINE_CALL_INPUT_",
             "call_input.env_collision",
             "workflow call input"
           ) do
      :ok
    end
  end

  defp build_environment(jobs) do
    collision =
      Enum.find_value(jobs, fn {job_id, job} ->
        case Enum.find(@build_environment_names, &Map.has_key?(job.env, &1)) do
          nil -> nil
          name -> {job_id, name}
        end
      end)

    case collision do
      nil ->
        :ok

      {job_id, name} ->
        {:error,
         Diagnostic.error(
           "build_provenance.env_collision",
           "environment #{name} is reserved for authoritative CI build provenance",
           ["jobs", job_id, "env", name]
         )}
    end
  end

  defp input_environment(definitions, jobs, prefix, code, label) do
    collision =
      Enum.find_value(jobs, fn {job_id, job} ->
        Enum.find_value(definitions, fn {input_id, _definition} ->
          name = prefix <> String.upcase(input_id)
          if Map.has_key?(job.env, name), do: {job_id, name}, else: nil
        end)
      end)

    case collision do
      nil ->
        :ok

      {job_id, name} ->
        {:error,
         Diagnostic.error(
           code,
           "environment #{name} is reserved for a #{label}",
           ["jobs", job_id, "env", name]
         )}
    end
  end

  defp jobs(%{"jobs" => jobs}, limits) when is_map(jobs) and map_size(jobs) > 0 do
    if map_size(jobs) > Keyword.fetch!(limits, :max_jobs) do
      {:error,
       Diagnostic.error(
         "workflow.limit_jobs",
         "workflow exceeds #{Keyword.fetch!(limits, :max_jobs)} jobs",
         ["jobs"]
       )}
    else
      normalize_jobs(jobs, limits)
    end
  end

  defp jobs(_document, _limits) do
    {:error, Diagnostic.error("workflow.jobs", "jobs must be a non-empty map", ["jobs"])}
  end

  defp normalize_jobs(jobs, limits) do
    {normalized, errors, warnings} =
      jobs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, [], []}, fn {id, definition}, {acc, errors, warnings} ->
        case job(id, definition, limits) do
          {:ok, normalized_job, job_warnings} ->
            {Map.put(acc, id, normalized_job), errors, warnings ++ job_warnings}

          {:error, job_errors} ->
            {acc, errors ++ job_errors, warnings}
        end
      end)

    reference_errors = dependency_reference_errors(normalized)
    all_errors = errors ++ reference_errors
    if all_errors == [], do: {:ok, normalized, warnings}, else: {:error, all_errors}
  end

  defp job(id, definition, limits) when is_binary(id) and is_map(definition) do
    errors =
      unknown_keys(definition, @job_keys, ["jobs", id]) ++
        if(Regex.match?(@job_id, id),
          do: [],
          else: [Diagnostic.error("job.id", "invalid job identifier", ["jobs", id])]
        )

    with [] <- errors,
         {:ok, image} <- nonempty_string(definition, "image", ["jobs", id, "image"]),
         {:ok, needs} <- needs(definition, id),
         {:ok, condition} <- condition(definition, ["jobs", id, "if"]),
         :ok <- valid_job_condition(condition, needs, id),
         {:ok, shell} <- shell(definition, id),
         {:ok, env} <- env(definition, id),
         {:ok, matrix} <- matrix(definition, id, env),
         {:ok, secrets} <- secrets(definition, id),
         {:ok, services} <- services(definition, id, secrets),
         {:ok, runs_on} <- runs_on(definition, id),
         {:ok, steps} <- steps(definition, id, limits) do
      warnings = image_warnings(image, id)

      {:ok,
       %Job{
         id: id,
         base_id: id,
         image: image,
         needs: needs,
         condition: condition,
         shell: shell,
         env: env,
         matrix: matrix,
         secrets: secrets,
         services: services,
         runs_on: runs_on,
         timeout: Map.get(definition, "timeout"),
         steps: steps
       }, warnings}
    else
      {:error, %Diagnostic{} = error} -> {:error, [error]}
      {:error, errors} -> {:error, errors}
    end
  end

  defp job(id, _definition, _limits) do
    {:error, [Diagnostic.error("job.type", "job must be a map", ["jobs", to_string(id)])]}
  end

  defp needs(definition, id) do
    case Map.get(definition, "needs", []) do
      needs when is_list(needs) ->
        if Enum.all?(needs, &is_binary/1) do
          {:ok, Enum.uniq(needs)}
        else
          {:error,
           Diagnostic.error(
             "job.needs",
             "needs must contain only job IDs",
             ["jobs", id, "needs"]
           )}
        end

      need when is_binary(need) ->
        {:ok, [need]}

      _ ->
        {:error,
         Diagnostic.error("job.needs", "needs must be a job ID or list", ["jobs", id, "needs"])}
    end
  end

  defp shell(definition, id) do
    case Map.get(definition, "shell", "/bin/sh") do
      shell when shell in ["/bin/sh", "/bin/bash"] ->
        {:ok, shell}

      _ ->
        {:error,
         Diagnostic.error("job.shell", "shell must be /bin/sh or /bin/bash", ["jobs", id, "shell"])}
    end
  end

  defp env(definition, id) do
    case Map.get(definition, "env", %{}) do
      env when is_map(env) ->
        if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
          {:ok, env}
        else
          {:error,
           Diagnostic.error("job.env", "environment keys and values must be strings", [
             "jobs",
             id,
             "env"
           ])}
        end

      _ ->
        {:error, Diagnostic.error("job.env", "env must be a map", ["jobs", id, "env"])}
    end
  end

  defp matrix(definition, job_id, env) do
    case Map.get(definition, "strategy") do
      nil ->
        {:ok, %{}}

      strategy when is_map(strategy) ->
        with [] <- unknown_keys(strategy, @strategy_keys, ["jobs", job_id, "strategy"]),
             {:ok, axes} <- matrix_axes(Map.get(strategy, "matrix"), job_id),
             :ok <- matrix_product(axes, job_id),
             :ok <- matrix_environment(axes, env, job_id) do
          {:ok, axes}
        else
          errors when is_list(errors) -> {:error, errors}
          {:error, %Diagnostic{} = error} -> {:error, error}
          {:error, errors} when is_list(errors) -> {:error, errors}
        end

      _invalid ->
        {:error,
         Diagnostic.error(
           "matrix.strategy",
           "strategy must be a map containing matrix",
           ["jobs", job_id, "strategy"]
         )}
    end
  end

  defp matrix_axes(matrix, job_id) when is_map(matrix) and map_size(matrix) in 1..4 do
    {axes, errors} =
      matrix
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, []}, fn {axis, values}, {axes, errors} ->
        path = ["jobs", job_id, "strategy", "matrix", to_string(axis)]

        cond do
          not (is_binary(axis) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,30}\z/, axis)) ->
            {axes, errors ++ [Diagnostic.error("matrix.axis", "invalid matrix axis", path)]}

          not (is_list(values) and length(values) in 1..8) ->
            {axes,
             errors ++
               [
                 Diagnostic.error(
                   "matrix.values",
                   "matrix axis must contain 1 to 8 values",
                   path
                 )
               ]}

          true ->
            invalid_index =
              Enum.find_index(values, fn value ->
                not (is_binary(value) and
                       Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, value))
              end)

            cond do
              invalid_index != nil ->
                {axes,
                 errors ++
                   [
                     Diagnostic.error(
                       "matrix.value",
                       "matrix values must be bounded safe strings",
                       path ++ [invalid_index]
                     )
                   ]}

              length(Enum.uniq(values)) != length(values) ->
                {axes,
                 errors ++
                   [
                     Diagnostic.error(
                       "matrix.value_duplicate",
                       "matrix values must be unique",
                       path
                     )
                   ]}

              true ->
                {Map.put(axes, axis, values), errors}
            end
        end
      end)

    if errors == [], do: {:ok, axes}, else: {:error, errors}
  end

  defp matrix_axes(_matrix, job_id) do
    {:error,
     Diagnostic.error(
       "matrix.axes",
       "matrix must contain 1 to 4 axes",
       ["jobs", job_id, "strategy", "matrix"]
     )}
  end

  defp matrix_product(axes, job_id) do
    product = Enum.reduce(axes, 1, fn {_axis, values}, count -> count * length(values) end)

    if product <= 32 do
      :ok
    else
      {:error,
       Diagnostic.error(
         "matrix.limit_variants",
         "matrix exceeds 32 variants",
         ["jobs", job_id, "strategy", "matrix"]
       )}
    end
  end

  defp matrix_environment(axes, env, job_id) do
    collision =
      axes
      |> Map.keys()
      |> Enum.map(&matrix_environment_name/1)
      |> Enum.find(&Map.has_key?(env, &1))

    if collision do
      {:error,
       Diagnostic.error(
         "matrix.env_collision",
         "environment #{collision} is reserved for the matrix axis",
         ["jobs", job_id, "env", collision]
       )}
    else
      :ok
    end
  end

  defp matrix_environment_name(axis), do: "ROBINE_MATRIX_" <> String.upcase(axis)

  defp secrets(definition, id) do
    case Map.get(definition, "secrets", []) do
      names when is_list(names) ->
        if Enum.all?(names, &(is_binary(&1) and Regex.match?(~r/\A[A-Z_][A-Z0-9_]*\z/, &1))) do
          {:ok, Enum.uniq(names)}
        else
          {:error,
           Diagnostic.error(
             "job.secrets",
             "secrets must contain valid secret names",
             ["jobs", id, "secrets"]
           )}
        end

      _ ->
        {:error,
         Diagnostic.error("job.secrets", "secrets must be a list", ["jobs", id, "secrets"])}
    end
  end

  defp services(definition, job_id, declared_secrets) do
    case Map.get(definition, "services", %{}) do
      services when is_map(services) and map_size(services) <= 8 ->
        normalize_services(services, job_id, declared_secrets)

      _invalid ->
        {:error,
         Diagnostic.error(
           "job.services",
           "services must be a map of at most 8 definitions",
           ["jobs", job_id, "services"]
         )}
    end
  end

  defp normalize_services(services, job_id, declared_secrets) do
    {normalized, errors} =
      services
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, []}, fn {service_id, definition}, {normalized, errors} ->
        case service(service_id, definition, job_id, declared_secrets) do
          {:ok, value} -> {Map.put(normalized, service_id, value), errors}
          {:error, service_errors} -> {normalized, errors ++ List.wrap(service_errors)}
        end
      end)

    if errors == [], do: {:ok, normalized}, else: {:error, errors}
  end

  defp service(service_id, definition, job_id, declared_secrets)
       when is_binary(service_id) and is_map(definition) do
    path = ["jobs", job_id, "services", service_id]

    errors =
      unknown_keys(definition, @service_keys, path) ++
        if(Regex.match?(@job_id, service_id),
          do: [],
          else: [Diagnostic.error("service.id", "invalid service identifier", path)]
        )

    with [] <- errors,
         {:ok, image} <- nonempty_string(definition, "image", path ++ ["image"]),
         {:ok, privileged} <- service_privileged(definition, service_id, image, path),
         {:ok, user} <- service_user(definition, path),
         {:ok, env} <- service_env(definition, path),
         {:ok, secret_env} <- service_secret_env(definition, path, declared_secrets),
         {:ok, command} <- service_command(definition, path),
         {:ok, readiness} <- service_readiness(definition, path) do
      {:ok,
       %Service{
         id: service_id,
         image: image,
         privileged: privileged,
         user: user,
         env: env,
         secret_env: secret_env,
         command: command,
         readiness: readiness
       }}
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, %Diagnostic{} = error} -> {:error, [error]}
      {:error, errors} -> {:error, List.wrap(errors)}
    end
  end

  defp service(service_id, _definition, job_id, _declared_secrets) do
    {:error,
     [
       Diagnostic.error("service.type", "service must be a map", [
         "jobs",
         job_id,
         "services",
         to_string(service_id)
       ])
     ]}
  end

  defp service_privileged(definition, service_id, image, path) do
    case Map.get(definition, "privileged", false) do
      false ->
        {:ok, false}

      true ->
        if service_id == "docker" and official_dind_image?(image),
          do: {:ok, true},
          else:
            {:error,
             Diagnostic.error(
               "service.privileged",
               "privileged services are restricted to a docker service using an official docker:*dind* image",
               path ++ ["privileged"]
             )}

      _invalid ->
        {:error,
         Diagnostic.error(
           "service.privileged",
           "privileged must be a boolean",
           path ++ ["privileged"]
         )}
    end
  end

  defp official_dind_image?(image) do
    Regex.match?(~r/\Adocker:[a-zA-Z0-9._-]*dind(?:-rootless)?\z/, image)
  end

  defp service_user(definition, path) do
    case Map.get(definition, "user") do
      nil ->
        {:ok, nil}

      user when is_binary(user) and byte_size(user) in 1..128 ->
        if Regex.match?(@container_user, user),
          do: {:ok, user},
          else: {:error, service_user_error(path)}

      _invalid ->
        {:error, service_user_error(path)}
    end
  end

  defp service_user_error(path) do
    Diagnostic.error(
      "service.user",
      "service user must be a bounded user or user:group identifier",
      path ++ ["user"]
    )
  end

  defp service_env(definition, path) do
    case Map.get(definition, "env", %{}) do
      env when is_map(env) and map_size(env) <= 64 ->
        if valid_service_environment?(env) do
          {:ok, env}
        else
          {:error, service_environment_error(path)}
        end

      _invalid ->
        {:error, service_environment_error(path)}
    end
  end

  defp service_environment_error(path) do
    Diagnostic.error(
      "service.env",
      "service env must contain at most 64 uppercase string entries",
      path ++ ["env"]
    )
  end

  defp valid_service_environment?(env) do
    Enum.all?(env, fn {key, value} ->
      is_binary(key) and Regex.match?(@env_name, key) and is_binary(value)
    end)
  end

  defp service_secret_env(definition, path, declared_secrets) do
    case Map.get(definition, "secret-env", %{}) do
      secret_env when is_map(secret_env) and map_size(secret_env) <= 64 ->
        if Enum.all?(secret_env, fn {environment_name, secret_name} ->
             is_binary(environment_name) and Regex.match?(@env_name, environment_name) and
               is_binary(secret_name) and secret_name in declared_secrets and
               not Map.has_key?(Map.get(definition, "env", %{}), environment_name)
           end) do
          {:ok, secret_env}
        else
          {:error,
           Diagnostic.error(
             "service.secret_env",
             "service secret-env values must reference declared secrets and cannot overlap env",
             path ++ ["secret-env"]
           )}
        end

      _invalid ->
        {:error,
         Diagnostic.error(
           "service.secret_env",
           "service secret-env must be a map of at most 64 entries",
           path ++ ["secret-env"]
         )}
    end
  end

  defp service_command(definition, path) do
    case Map.get(definition, "command", []) do
      command when is_list(command) and length(command) <= 32 ->
        if Enum.all?(command, &(is_binary(&1) and byte_size(&1) in 1..4_096)) do
          {:ok, command}
        else
          {:error, service_command_error(path)}
        end

      _invalid ->
        {:error, service_command_error(path)}
    end
  end

  defp service_command_error(path) do
    Diagnostic.error(
      "service.command",
      "service command must contain at most 32 bounded string arguments",
      path ++ ["command"]
    )
  end

  defp service_readiness(definition, path) do
    case Map.get(definition, "readiness") do
      nil ->
        {:ok, nil}

      readiness when is_map(readiness) ->
        with [] <- unknown_keys(readiness, @readiness_keys, path ++ ["readiness"]),
             port when is_integer(port) and port in 1..65_535 <- Map.get(readiness, "tcp"),
             {:ok, timeout_ms} <- service_timeout(Map.get(readiness, "timeout", "30s")) do
          {:ok, %{tcp: port, timeout_ms: timeout_ms}}
        else
          errors when is_list(errors) -> {:error, errors}
          _invalid -> {:error, service_readiness_error(path)}
        end

      _invalid ->
        {:error, service_readiness_error(path)}
    end
  end

  defp service_readiness_error(path) do
    Diagnostic.error(
      "service.readiness",
      "readiness requires tcp 1..65535 and timeout from 1s to 120s",
      path ++ ["readiness"]
    )
  end

  defp service_timeout(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+)s\z/, value) do
      [_, seconds] ->
        seconds = String.to_integer(seconds)
        if seconds in 1..120, do: {:ok, seconds * 1_000}, else: :error

      _invalid ->
        :error
    end
  end

  defp service_timeout(_value), do: :error

  defp runs_on(definition, id) do
    case Map.get(definition, "runs-on", ["docker"]) do
      labels when is_list(labels) and labels != [] and length(labels) <= 16 ->
        case Enum.find_index(labels, &(not valid_runner_label?(&1))) do
          nil ->
            {:ok, Enum.uniq(labels)}

          index ->
            {:error,
             Diagnostic.error(
               "job.runs_on",
               "runs-on labels must be lowercase ASCII and contain only letters, digits, ., _, or -",
               ["jobs", id, "runs-on", index]
             )}
        end

      _invalid ->
        {:error,
         Diagnostic.error(
           "job.runs_on",
           "runs-on must be a non-empty list of at most 16 labels",
           ["jobs", id, "runs-on"]
         )}
    end
  end

  defp valid_runner_label?(label),
    do: is_binary(label) and Regex.match?(@runner_label, label)

  defp steps(%{"steps" => steps}, id, limits) when is_list(steps) and steps != [] do
    if length(steps) > Keyword.fetch!(limits, :max_steps_per_job) do
      {:error,
       Diagnostic.error(
         "workflow.limit_steps_per_job",
         "job exceeds #{Keyword.fetch!(limits, :max_steps_per_job)} steps",
         ["jobs", id, "steps"]
       )}
    else
      normalize_steps(steps, id)
    end
  end

  defp steps(_definition, id, _limits) do
    {:error,
     Diagnostic.error("job.steps", "steps must be a non-empty list", ["jobs", id, "steps"])}
  end

  defp normalize_steps(steps, id) do
    {normalized, errors} =
      steps
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {definition, index}, {acc, errors} ->
        case step(definition, id, index) do
          {:ok, value} -> {[value | acc], errors}
          {:error, step_errors} -> {acc, errors ++ step_errors}
        end
      end)

    normalized = Enum.reverse(normalized)
    duplicate_errors = duplicate_step_names(normalized, id)
    all_errors = errors ++ duplicate_errors
    if all_errors == [], do: {:ok, normalized}, else: {:error, all_errors}
  end

  defp step(definition, job_id, index) when is_map(definition) do
    path = ["jobs", job_id, "steps", index]
    errors = unknown_keys(definition, @step_keys, path)
    run = Map.get(definition, "run")
    builtin = Map.get(definition, "uses")

    kind_result =
      case {run, builtin} do
        {command, nil} when is_binary(command) and byte_size(command) > 0 ->
          {:ok, :run, command}

        {nil, name} when name in @builtins ->
          {:ok, :builtin, name}

        {nil, name} when is_binary(name) ->
          {:error,
           Diagnostic.error(
             "step.builtin",
             "unsupported built-in #{inspect(name)}",
             path ++ ["uses"]
           )}

        _ ->
          {:error,
           Diagnostic.error("step.action", "step must contain exactly one of run or uses", path)}
      end

    with [] <- errors,
         {:ok, kind, value} <- kind_result,
         {:ok, condition} <- condition(definition, path ++ ["if"]),
         {:ok, options} <- step_options(kind, value, Map.get(definition, "with", %{}), path) do
      name = Map.get(definition, "name") || default_step_name(kind, value, index)

      if is_binary(name) and byte_size(name) > 0 do
        {:ok, %Step{name: name, kind: kind, value: value, condition: condition, with: options}}
      else
        {:error, [Diagnostic.error("step.name", "step name must be a string", path ++ ["name"])]}
      end
    else
      errors when is_list(errors) -> {:error, errors}
      {:error, %Diagnostic{} = error} -> {:error, [error]}
      {:error, errors} when is_list(errors) -> {:error, errors}
    end
  end

  defp step(_definition, job_id, index) do
    {:error,
     [Diagnostic.error("step.type", "step must be a map", ["jobs", job_id, "steps", index])]}
  end

  defp default_step_name(:builtin, value, _index), do: value
  defp default_step_name(:run, _value, index), do: "Run #{index + 1}"

  defp condition(definition, path) do
    case Map.get(definition, "if", "success") do
      "success" ->
        {:ok, :success}

      "failure" ->
        {:ok, :failure}

      "always" ->
        {:ok, :always}

      _invalid ->
        {:error,
         Diagnostic.error("condition.value", "if must be success, failure, or always", path)}
    end
  end

  defp valid_job_condition(:failure, [], id) do
    {:error,
     Diagnostic.error(
       "job.condition_dependencies",
       "a failure job must declare at least one dependency",
       ["jobs", id, "if"]
     )}
  end

  defp valid_job_condition(_condition, _needs, _id), do: :ok

  defp step_options(:run, _value, options, _path) when options == %{}, do: {:ok, %{}}

  defp step_options(:run, _value, _options, path) do
    {:error, Diagnostic.error("step.with", "run steps do not accept with", path ++ ["with"])}
  end

  defp step_options(:builtin, _value, options, path) when not is_map(options) do
    {:error, Diagnostic.error("step.with", "with must be a map", path ++ ["with"])}
  end

  defp step_options(:builtin, "checkout", options, path) do
    exact_options(options, [], path)
  end

  defp step_options(:builtin, builtin, options, path)
       when builtin in ["cache/restore", "cache/save"] do
    with {:ok, options} <- exact_options(options, ~w(key paths), path),
         true <- valid_cache_key?(options["key"]),
         true <- valid_paths?(options["paths"]) do
      {:ok, options}
    else
      false ->
        {:error,
         Diagnostic.error(
           "step.cache_inputs",
           "cache requires a bounded key and 1 to 32 safe relative paths",
           path ++ ["with"]
         )}

      error ->
        error
    end
  end

  defp step_options(:builtin, "artifacts/upload", options, path) do
    with {:ok, options} <- exact_options(options, ~w(name paths retention-days), path),
         true <- valid_artifact_name?(options["name"]),
         true <- valid_paths?(options["paths"]),
         true <- valid_retention_days?(Map.get(options, "retention-days", 7)) do
      {:ok, Map.put_new(options, "retention-days", 7)}
    else
      false ->
        {:error,
         Diagnostic.error(
           "step.artifact_upload_inputs",
           "artifact upload requires a safe name, 1 to 32 relative paths, and retention-days from 1 to 90",
           path ++ ["with"]
         )}

      error ->
        error
    end
  end

  defp step_options(:builtin, "artifacts/download", options, path) do
    with {:ok, options} <- exact_options(options, ~w(name from path), path),
         true <- valid_artifact_name?(options["name"]),
         true <- is_binary(options["from"]) and Regex.match?(@job_id, options["from"]),
         true <- safe_path?(Map.get(options, "path", ".")) do
      {:ok, Map.put_new(options, "path", ".")}
    else
      false ->
        {:error,
         Diagnostic.error(
           "step.artifact_download_inputs",
           "artifact download requires a safe name, source job, and relative destination",
           path ++ ["with"]
         )}

      error ->
        error
    end
  end

  defp exact_options(options, allowed, path) do
    case unknown_keys(options, allowed, path ++ ["with"]) do
      [] -> {:ok, options}
      errors -> {:error, errors}
    end
  end

  defp valid_cache_key?(key) when is_binary(key) and byte_size(key) in 1..512 do
    expressions = Regex.scan(~r/\$\{\{.*?\}\}/, key) |> List.flatten()

    Enum.all?(expressions, fn expression ->
      case Regex.run(~r/\A\$\{\{\s*checksum\('([^']+)'\)\s*\}\}\z/, expression) do
        [_, path] -> safe_path?(path)
        _ -> false
      end
    end) and not String.contains?(Regex.replace(~r/\$\{\{.*?\}\}/, key, ""), "${{")
  end

  defp valid_cache_key?(_key), do: false

  defp valid_paths?(paths) when is_list(paths) and length(paths) in 1..32,
    do: Enum.all?(paths, &safe_path?/1)

  defp valid_paths?(_paths), do: false

  defp safe_path?(path) when is_binary(path) and byte_size(path) in 1..1_024 do
    Path.type(path) == :relative and ".." not in Path.split(path) and
      not String.contains?(path, <<0>>)
  end

  defp safe_path?(_path), do: false

  defp valid_artifact_name?(name) when is_binary(name) and byte_size(name) <= 192 do
    resolved =
      name
      |> String.replace("${{ runner.os }}", "linux")
      |> String.replace("${{ runner.arch }}", "amd64")

    not String.contains?(resolved, "${{") and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, resolved)
  end

  defp valid_artifact_name?(_name), do: false

  defp valid_retention_days?(days), do: is_integer(days) and days in 1..90

  defp duplicate_step_names(steps, job_id) do
    steps
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_name, values} -> length(values) > 1 end)
    |> Enum.map(fn {name, _values} ->
      Diagnostic.error("step.name_duplicate", "duplicate step name #{inspect(name)}", [
        "jobs",
        job_id,
        "steps"
      ])
    end)
  end

  defp expand_matrices(base_jobs, limits) do
    variants_by_base =
      Map.new(base_jobs, fn {base_id, job} ->
        variants =
          job.matrix
          |> matrix_combinations()
          |> Enum.map(&expand_matrix_job(job, &1))

        {base_id, variants}
      end)

    expanded_count =
      variants_by_base |> Map.values() |> Enum.reduce(0, &(length(&1) + &2))

    if expanded_count > Keyword.fetch!(limits, :max_jobs) do
      {:error,
       Diagnostic.error(
         "workflow.limit_jobs",
         "expanded workflow exceeds #{Keyword.fetch!(limits, :max_jobs)} jobs",
         ["jobs"]
       )}
    else
      variants_by_base
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, %{}}, fn {_base_id, variants}, {:ok, expanded} ->
        Enum.reduce_while(variants, {:ok, expanded}, fn job, {:ok, jobs} ->
          needs =
            Enum.flat_map(job.needs, fn base_need ->
              variants_by_base |> Map.fetch!(base_need) |> Enum.map(& &1.id)
            end)

          cond do
            byte_size(job.id) > 255 ->
              diagnostic =
                Diagnostic.error(
                  "matrix.generated_id",
                  "generated matrix job key exceeds 255 bytes",
                  ["jobs", job.base_id, "strategy", "matrix"]
                )

              {:halt, {:error, diagnostic}}

            true ->
              case interpolate_job_images(%{job | needs: needs}) do
                {:ok, interpolated} ->
                  {:cont, {:ok, Map.put(jobs, interpolated.id, interpolated)}}

                {:error, diagnostic} ->
                  {:halt, {:error, diagnostic}}
              end
          end
        end)
        |> case do
          {:ok, jobs} -> {:cont, {:ok, jobs}}
          {:error, diagnostic} -> {:halt, {:error, diagnostic}}
        end
      end)
    end
  end

  defp matrix_combinations(matrix) when map_size(matrix) == 0, do: [%{}]

  defp matrix_combinations(matrix) do
    matrix
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce([%{}], fn {axis, values}, combinations ->
      for combination <- combinations, value <- values, do: Map.put(combination, axis, value)
    end)
  end

  defp expand_matrix_job(job, values) when map_size(values) == 0,
    do: %{job | matrix: %{}, matrix_values: %{}}

  defp expand_matrix_job(job, values) do
    suffix =
      values
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {axis, value} -> "#{axis}=#{value}" end)

    matrix_env = Map.new(values, fn {axis, value} -> {matrix_environment_name(axis), value} end)

    %{
      job
      | id: "#{job.id}[#{suffix}]",
        env: Map.merge(job.env, matrix_env),
        matrix: %{},
        matrix_values: values
    }
  end

  defp interpolate_job_images(job) do
    with {:ok, image} <-
           interpolate_matrix_image(job.image, job.matrix_values, ["jobs", job.base_id, "image"]),
         {:ok, services} <- interpolate_service_images(job) do
      {:ok, %{job | image: image, services: services}}
    end
  end

  defp interpolate_service_images(job) do
    job.services
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {service_id, service}, {:ok, services} ->
      path = ["jobs", job.base_id, "services", service_id, "image"]

      case interpolate_matrix_image(service.image, job.matrix_values, path) do
        {:ok, image} -> {:cont, {:ok, Map.put(services, service_id, %{service | image: image})}}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp interpolate_matrix_image(image, values, path) do
    tokens = Regex.scan(~r/\$\{\{.*?\}\}/, image) |> List.flatten()

    Enum.reduce_while(tokens, {:ok, image}, fn token, {:ok, expanded} ->
      case Regex.run(~r/\A\$\{\{\s*matrix\.([a-z][a-z0-9_]{0,30})\s*\}\}\z/, token) do
        [_, axis] ->
          case Map.fetch(values, axis) do
            {:ok, value} -> {:cont, {:ok, String.replace(expanded, token, value)}}
            :error -> {:halt, {:error, matrix_interpolation_error(path, axis)}}
          end

        _invalid ->
          {:halt, {:error, matrix_interpolation_error(path, nil)}}
      end
    end)
    |> case do
      {:ok, expanded} ->
        if String.contains?(expanded, "${{"),
          do: {:error, matrix_interpolation_error(path, nil)},
          else: {:ok, expanded}

      error ->
        error
    end
  end

  defp matrix_interpolation_error(path, axis) do
    detail = if axis, do: "unknown matrix axis #{inspect(axis)}", else: "invalid matrix token"

    Diagnostic.error(
      "matrix.interpolation",
      "#{detail}; images accept only ${{ matrix.axis }}",
      path
    )
  end

  defp dependency_reference_errors(jobs) do
    Enum.flat_map(jobs, fn {id, job} ->
      need_errors =
        Enum.flat_map(job.needs, fn dependency ->
          if Map.has_key?(jobs, dependency) do
            []
          else
            [
              Diagnostic.error(
                "job.need_unknown",
                "unknown dependency #{inspect(dependency)}",
                ["jobs", id, "needs"]
              )
            ]
          end
        end)

      artifact_errors =
        job.steps
        |> Enum.with_index()
        |> Enum.flat_map(fn {step, index} ->
          source = step.with["from"]

          cond do
            step.kind != :builtin or step.value != "artifacts/download" ->
              []

            source not in job.needs ->
              [
                Diagnostic.error(
                  "step.artifact_dependency",
                  "artifact source #{inspect(source)} must be declared in job needs",
                  ["jobs", id, "steps", index, "with", "from"]
                )
              ]

            Map.has_key?(jobs, source) and map_size(jobs[source].matrix) > 0 ->
              [
                Diagnostic.error(
                  "matrix.artifact_ambiguous",
                  "artifact source #{inspect(source)} expands to multiple variants",
                  ["jobs", id, "steps", index, "with", "from"]
                )
              ]

            true ->
              []
          end
        end)

      need_errors ++ artifact_errors
    end)
  end

  defp topological_order(jobs) do
    indegrees = Map.new(jobs, fn {id, job} -> {id, length(job.needs)} end)

    ready =
      indegrees
      |> Enum.filter(fn {_id, count} -> count == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {order, remaining} = consume_graph(ready, jobs, indegrees, [])

    if map_size(remaining) == 0 do
      {:ok, order}
    else
      cycle_ids = remaining |> Map.keys() |> Enum.sort()

      {:error,
       Enum.map(cycle_ids, fn id ->
         Diagnostic.error("workflow.cycle", "job participates in a dependency cycle", [
           "jobs",
           id,
           "needs"
         ])
       end)}
    end
  end

  defp consume_graph([], _jobs, indegrees, order), do: {Enum.reverse(order), indegrees}

  defp consume_graph([id | ready], jobs, indegrees, order) do
    remaining = Map.delete(indegrees, id)

    {remaining, newly_ready} =
      jobs
      |> Enum.filter(fn {_candidate_id, job} -> id in job.needs end)
      |> Enum.reduce({remaining, []}, fn {candidate_id, _job}, {counts, released} ->
        case Map.fetch(counts, candidate_id) do
          {:ok, count} when count - 1 == 0 ->
            {Map.put(counts, candidate_id, 0), [candidate_id | released]}

          {:ok, count} ->
            {Map.put(counts, candidate_id, count - 1), released}

          :error ->
            {counts, released}
        end
      end)

    consume_graph(Enum.sort(ready ++ newly_ready), jobs, remaining, [id | order])
  end

  defp graph_limits(jobs, order, limits) do
    total_steps = jobs |> Map.values() |> Enum.sum_by(&length(&1.steps))

    depths =
      Enum.reduce(order, %{}, fn id, acc ->
        parents = jobs[id].needs
        depth = if parents == [], do: 1, else: 1 + Enum.max(Enum.map(parents, &acc[&1]))
        Map.put(acc, id, depth)
      end)

    max_depth = depths |> Map.values() |> Enum.max(fn -> 0 end)

    cond do
      total_steps > Keyword.fetch!(limits, :max_total_steps) ->
        {:error,
         Diagnostic.error(
           "workflow.limit_total_steps",
           "workflow exceeds #{Keyword.fetch!(limits, :max_total_steps)} total steps",
           ["jobs"]
         )}

      max_depth > Keyword.fetch!(limits, :max_graph_depth) ->
        {:error,
         Diagnostic.error(
           "workflow.limit_graph_depth",
           "workflow exceeds dependency depth #{Keyword.fetch!(limits, :max_graph_depth)}",
           ["jobs"]
         )}

      true ->
        :ok
    end
  end

  defp image_warnings(image, id) do
    if String.contains?(image, "@sha256:") do
      []
    else
      [
        Diagnostic.warning("job.image_mutable", "image is not pinned by digest", [
          "jobs",
          id,
          "image"
        ])
      ]
    end
  end

  defp nonempty_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      _ ->
        {:error, Diagnostic.error("workflow.required", "#{key} must be a non-empty string", path)}
    end
  end

  defp unknown_keys(map, allowed, path) do
    map
    |> Map.keys()
    |> Enum.reject(fn key ->
      is_binary(key) and (key in allowed or String.starts_with?(key, "x-"))
    end)
    |> Enum.sort()
    |> Enum.map(fn key ->
      Diagnostic.error(
        "workflow.unknown_key",
        "unknown key #{inspect(key)}",
        path ++ [to_string(key)]
      )
    end)
  end
end
