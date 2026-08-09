defmodule Robine.Adapters.Execution.DockerRunnerTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Execution.DockerRunner
  alias Robine.Execution.Contracts.{Specification, Step}

  test "translates bounded runner resources to Docker create arguments" do
    assert DockerRunner.resource_limit_args(
             cpu_millis: 1_250,
             memory_bytes: 536_870_912,
             pids_limit: 64
           ) == [
             "--cpus",
             "1.250",
             "--memory",
             "536870912",
             "--memory-swap",
             "536870912",
             "--pids-limit",
             "64"
           ]
  end

  @tag :docker
  test "runs sequential steps in one container and always cleans resources" do
    attempt_id = "docker-test-#{System.unique_integer([:positive])}"

    source_path =
      Path.join(System.tmp_dir!(), "robine-runner-source-#{System.unique_integer([:positive])}")

    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "checked-out.txt"), "exact source")
    on_exit(fn -> File.rm_rf!(source_path) end)

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      source_path: source_path,
      env: %{"VISIBLE" => "yes"},
      secrets: %{},
      steps: [
        %Step{name: "Write", kind: :run, value: "printf shared > state.txt"},
        %Step{
          name: "Read",
          kind: :run,
          value: "printf '%s:%s:%s' \"$(cat state.txt)\" \"$VISIBLE\" \"$(cat checked-out.txt)\""
        }
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :succeeded, inspect(result)
    assert Enum.at(result.steps, 1).output == "shared:yes:exact source"
    assert result.cleanup_warning == nil

    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    resource = "robine-#{suffix}"

    {_output, exit_code} =
      System.cmd("docker", ["container", "inspect", resource], stderr_to_stdout: true)

    assert exit_code == 1
  end

  @tag :docker
  test "stops after a command failure and returns its output" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-failure-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [
        %Step{name: "Fail", kind: :run, value: "echo broken; exit 7"},
        %Step{name: "Never", kind: :run, value: "echo no"}
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :failed
    assert result.reason == :command_failed
    assert [%{name: "Fail", exit_code: 7, output: "broken\n"}] = result.steps
  end

  @tag :docker
  test "redacts secret values before returning command output" do
    secret = "runner-secret-value"

    specification = %Specification{
      version: 1,
      attempt_id: "docker-secret-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{"TOKEN" => secret},
      steps: [%Step{name: "Print", kind: :run, value: "printf '%s' \"$TOKEN\""}]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert [%{output: "[REDACTED]"}] = result.steps
    refute inspect(result) =~ secret
  end

  @tag :docker
  test "streams redacted chunks before a long-running step completes" do
    parent = self()
    secret = "stream-secret-value"

    specification = %Specification{
      version: 1,
      attempt_id: "docker-stream-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{"TOKEN" => secret},
      steps: [
        %Step{
          name: "Stream",
          kind: :run,
          value: "printf 'first\\nstream-'; sleep 1; printf 'secret-value\\nlast\\n'"
        }
      ]
    }

    task =
      Task.async(fn ->
        DockerRunner.run(specification, fn event ->
          send(parent, {:stream_event, event})
          :ok
        end)
      end)

    assert_receive {:stream_event,
                    %{step_name: "Image acquisition", status: :running, content: _}},
                   3_000

    assert_receive {:stream_event, %{step_name: "Stream", status: :running, content: first}},
                   3_000

    assert first =~ "first"
    refute first =~ "stream-"
    assert Task.yield(task, 0) == nil

    assert {:ok, result} = Task.await(task, 5_000)
    assert result.status == :succeeded
    refute inspect(result) =~ secret

    events = collect_stream_events([])
    rendered = Enum.map_join(events, & &1.content)
    assert rendered =~ "[REDACTED]"
    refute rendered =~ secret
    assert Enum.any?(events, &(&1.status == :succeeded))
  end

  @tag :docker
  test "saves and restores cache and artifact archives through the builtin callback" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-builtins-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [
        %Step{
          name: "Prepare",
          kind: :run,
          value:
            "mkdir -p deps reports; printf cache > deps/value; printf artifact > reports/result"
        },
        %Step{
          name: "Save cache",
          kind: :builtin,
          value: "cache/save",
          with: %{"key" => "deps-v1", "paths" => ["deps"]}
        },
        %Step{
          name: "Upload",
          kind: :builtin,
          value: "artifacts/upload",
          with: %{"name" => "reports", "paths" => ["reports"], "retention-days" => 7}
        },
        %Step{name: "Clear", kind: :run, value: "rm -rf deps reports"},
        %Step{
          name: "Restore cache",
          kind: :builtin,
          value: "cache/restore",
          with: %{"key" => "deps-v1", "paths" => ["deps"]}
        },
        %Step{
          name: "Download",
          kind: :builtin,
          value: "artifacts/download",
          with: %{"name" => "reports", "from" => "build", "path" => "."}
        },
        %Step{
          name: "Verify",
          kind: :run,
          value: "printf '%s:%s' \"$(cat deps/value)\" \"$(cat reports/result)\""
        }
      ]
    }

    callback = fn
      %{type: :builtin, phase: :publish, builtin: builtin, content: content} ->
        Process.put({:archive, builtin}, content)
        {:ok, %{size: byte_size(content)}}

      %{type: :builtin, phase: :restore, builtin: "cache/restore"} ->
        {:ok, %{content: Process.get({:archive, "cache/save"})}}

      %{type: :builtin, phase: :restore, builtin: "artifacts/download"} ->
        {:ok, %{content: Process.get({:archive, "artifacts/upload"})}}

      _event ->
        :ok
    end

    assert {:ok, result} = DockerRunner.run(specification, callback)
    assert result.status == :succeeded, inspect(result)
    assert List.last(result.steps).output == "cache:artifact"
  end

  @tag :docker
  test "treats a cache miss as a successful visible step" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-cache-miss-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [
        %Step{
          name: "Restore",
          kind: :builtin,
          value: "cache/restore",
          with: %{"key" => "missing", "paths" => ["deps"]}
        }
      ]
    }

    callback = fn
      %{type: :builtin} -> {:ok, :miss}
      _event -> :ok
    end

    assert {:ok, result} = DockerRunner.run(specification, callback)
    assert [%{status: :succeeded, output: "Cache miss: missing"}] = result.steps
  end

  @tag :docker
  test "reports a missing configured shell as a preparation failure" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-shell-#{System.unique_integer([:positive])}",
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/bash",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [%Step{name: "Never", kind: :run, value: "true"}]
    }

    assert {:error, {:docker, {:shell_unavailable, "/bin/bash", _reason}}} =
             DockerRunner.run(specification)
  end

  test "parses labeled Docker resource projections" do
    output = "abc attempt-one\ndef attempt-two\n"

    assert {:ok,
            [
              %{name: "abc", attempt_id: "attempt-one"},
              %{name: "def", attempt_id: "attempt-two"}
            ]} = DockerRunner.parse_labeled_resources(output)

    assert {:error, :invalid_labeled_resource_output} =
             DockerRunner.parse_labeled_resources("missing-label")
  end

  @tag :docker
  test "removes only labeled resources whose durable attempt is no longer active" do
    suffix = System.unique_integer([:positive])
    orphan_attempt = "orphan-attempt-#{suffix}"
    active_attempt = "active-attempt-#{suffix}"
    orphan_container = "robine-test-orphan-#{suffix}"
    active_container = "robine-test-active-#{suffix}"
    orphan_volume = orphan_container <> "-volume"
    active_volume = active_container <> "-volume"

    on_exit(fn ->
      System.cmd("docker", ["rm", "--force", orphan_container], stderr_to_stdout: true)
      System.cmd("docker", ["rm", "--force", active_container], stderr_to_stdout: true)
      System.cmd("docker", ["volume", "rm", "--force", orphan_volume], stderr_to_stdout: true)
      System.cmd("docker", ["volume", "rm", "--force", active_volume], stderr_to_stdout: true)
    end)

    docker!([
      "create",
      "--name",
      orphan_container,
      "--label",
      "io.robine.attempt=#{orphan_attempt}",
      "alpine:3.22",
      "sleep",
      "3600"
    ])

    docker!([
      "create",
      "--name",
      active_container,
      "--label",
      "io.robine.attempt=#{active_attempt}",
      "alpine:3.22",
      "sleep",
      "3600"
    ])

    docker!(["volume", "create", "--label", "io.robine.attempt=#{orphan_attempt}", orphan_volume])
    docker!(["volume", "create", "--label", "io.robine.attempt=#{active_attempt}", active_volume])

    assert {:ok, %{containers_removed: containers, volumes_removed: volumes}} =
             DockerRunner.reconcile_resources([active_attempt])

    assert containers >= 1
    assert volumes >= 1

    assert docker_status(["container", "inspect", orphan_container]) == 1
    assert docker_status(["volume", "inspect", orphan_volume]) == 1
    assert docker_status(["container", "inspect", active_container]) == 0
    assert docker_status(["volume", "inspect", active_volume]) == 0
  end

  @tag :docker
  test "cancels a running command, stops its container, and skips remaining steps" do
    previous = Application.fetch_env!(:robine, :runner_cancellation_grace_ms)
    Application.put_env(:robine, :runner_cancellation_grace_ms, 1_000)
    on_exit(fn -> Application.put_env(:robine, :runner_cancellation_grace_ms, previous) end)

    attempt_id = "docker-cancel-#{System.unique_integer([:positive])}"
    started = System.monotonic_time(:millisecond)

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [
        %Step{name: "Long", kind: :run, value: "echo started; sleep 30"},
        %Step{name: "Never", kind: :run, value: "echo should-not-run"}
      ]
    }

    cancel_requested = fn -> System.monotonic_time(:millisecond) - started > 700 end

    assert {:ok, result} = DockerRunner.run(specification, fn _event -> :ok end, cancel_requested)
    assert result.status == :cancelled
    assert result.reason == :cancelled
    assert [%{name: "Long", output: output}] = result.steps
    assert output =~ "job cancelled"
    refute output =~ "should-not-run"
    assert System.monotonic_time(:millisecond) - started < 5_000

    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    assert docker_status(["container", "inspect", "robine-#{suffix}"]) == 1
  end

  defp collect_stream_events(events) do
    receive do
      {:stream_event, event} -> collect_stream_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp docker!(arguments) do
    {_output, 0} = System.cmd("docker", arguments, stderr_to_stdout: true)
    :ok
  end

  defp docker_status(arguments) do
    {_output, status} = System.cmd("docker", arguments, stderr_to_stdout: true)
    status
  end
end
