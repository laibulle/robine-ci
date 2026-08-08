defmodule Robine.Adapters.Execution.DockerRunner do
  @moduledoc false
  @behaviour Robine.Execution.Ports.Runner

  alias Robine.Execution.Contracts.{Result, Specification, Step, StepResult}

  @output_limit 10_000_000

  @impl true
  def run(%Specification{} = specification) do
    started_at = DateTime.utc_now()
    resource = resource_name(specification.attempt_id)
    volume = resource <> "-workspace"

    with :ok <- ensure_resource_absent(resource),
         {:ok, _output} <- docker(["volume", "create", "--label", label(specification), volume]),
         {:ok, _output} <- create_container(specification, resource, volume),
         {:ok, _output} <- docker(["start", resource]),
         {:ok, step_results} <- run_steps(specification, resource) do
      cleanup_warning = cleanup(resource, volume)

      {:ok,
       %Result{
         attempt_id: specification.attempt_id,
         status: :succeeded,
         reason: nil,
         steps: step_results,
         started_at: started_at,
         finished_at: DateTime.utc_now(),
         cleanup_warning: cleanup_warning
       }}
    else
      {:step_failed, step_results, reason} ->
        cleanup_warning = cleanup(resource, volume)

        {:ok,
         %Result{
           attempt_id: specification.attempt_id,
           status: :failed,
           reason: reason,
           steps: step_results,
           started_at: started_at,
           finished_at: DateTime.utc_now(),
           cleanup_warning: cleanup_warning
         }}

      {:error, reason} ->
        _cleanup_warning = cleanup(resource, volume)
        {:error, {:docker, reason}}
    end
  end

  defp ensure_resource_absent(resource) do
    case docker(["container", "inspect", resource]) do
      {:error, %{exit_code: 1}} -> :ok
      {:ok, _output} -> {:error, :duplicate_attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_container(specification, resource, volume) do
    args =
      [
        "create",
        "--name",
        resource,
        "--label",
        label(specification),
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--network",
        "bridge",
        "--mount",
        "type=volume,source=#{volume},target=#{specification.workspace}",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,size=256m"
      ] ++
        environment_args(specification.env) ++
        environment_args(specification.secrets) ++
        [
          specification.image,
          specification.shell,
          "-c",
          "trap 'exit 0' TERM INT; while :; do sleep 3600; done"
        ]

    docker(args, specification.timeout_ms)
  end

  defp run_steps(specification, resource) do
    Enum.reduce_while(specification.steps, {:ok, []}, fn step, {:ok, results} ->
      case run_step(step, specification, resource) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:failed, result, reason} -> {:halt, {:step_failed, results ++ [result], reason}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_step(%Step{kind: :run} = step, specification, resource) do
    started = System.monotonic_time(:millisecond)

    args = [
      "exec",
      "--workdir",
      specification.workspace,
      resource,
      specification.shell,
      "-e",
      "-c",
      step.value
    ]

    case docker(args, specification.timeout_ms) do
      {:ok, output} ->
        {:ok,
         step_result(
           step,
           :succeeded,
           0,
           output,
           started,
           Map.values(specification.secrets)
         )}

      {:error, %{exit_code: 124, output: output}} ->
        {:failed,
         step_result(
           step,
           :timed_out,
           nil,
           output,
           started,
           Map.values(specification.secrets)
         ), :timeout}

      {:error, %{exit_code: exit_code, output: output}} ->
        {:failed,
         step_result(
           step,
           :failed,
           exit_code,
           output,
           started,
           Map.values(specification.secrets)
         ), :command_failed}
    end
  end

  defp run_step(%Step{kind: :builtin, value: value}, _specification, _resource),
    do: {:error, {:unsupported_builtin, value}}

  defp step_result(step, status, exit_code, output, started, secret_values) do
    %StepResult{
      name: step.name,
      status: status,
      exit_code: exit_code,
      output: redact_and_truncate(output, secret_values),
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp docker(args, timeout_ms \\ 30_000) do
    task = Task.async(fn -> System.cmd("docker", args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, truncate_output(output)}

      {:ok, {output, exit_code}} ->
        {:error, %{exit_code: exit_code, output: truncate_output(output)}}

      nil ->
        {:error, %{exit_code: 124, output: "command timed out"}}
    end
  rescue
    error -> {:error, %{exit_code: nil, output: Exception.message(error)}}
  end

  defp cleanup(resource, volume) do
    container_result = docker(["rm", "--force", resource])
    volume_result = docker(["volume", "rm", "--force", volume])

    case {ignorable_cleanup(container_result), ignorable_cleanup(volume_result)} do
      {:ok, :ok} -> nil
      other -> inspect(other)
    end
  end

  defp ignorable_cleanup({:ok, _output}), do: :ok
  defp ignorable_cleanup({:error, %{exit_code: 1}}), do: :ok
  defp ignorable_cleanup(error), do: error

  defp environment_args(environment) do
    environment
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp resource_name(attempt_id) do
    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    "robine-#{suffix}"
  end

  defp label(specification), do: "io.robine.attempt=#{specification.attempt_id}"

  defp truncate_output(output) when byte_size(output) <= @output_limit, do: output

  defp truncate_output(output),
    do: binary_part(output, 0, @output_limit) <> "\n[output truncated]"

  defp redact_and_truncate(output, []), do: truncate_output(output)

  defp redact_and_truncate(output, secret_values) do
    case Robine.Secrets.redact_output(%{output: output, values: secret_values}) do
      {:ok, redacted} -> truncate_output(redacted)
      {:error, _reason} -> "[output unavailable: redaction failed]"
    end
  end
end
