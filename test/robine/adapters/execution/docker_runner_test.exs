defmodule Robine.Adapters.Execution.DockerRunnerTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Execution.DockerRunner
  alias Robine.Execution.Contracts.{Service, Specification, Step}

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

  test "allocates one GiB of temporary storage to job and service containers" do
    assert DockerRunner.tmpfs_args() == ["--tmpfs", "/tmp:rw,noexec,nosuid,size=1g"]
  end

  test "renders the retained Docker state with an actionable OOM diagnostic" do
    assert DockerRunner.container_state_diagnostic(%{
             "Status" => "exited",
             "ExitCode" => 137,
             "OOMKilled" => true,
             "Error" => "",
             "FinishedAt" => "2026-08-10T11:42:00Z"
           }) ==
             "Container stopped unexpectedly: status=exited, exit_code=137, " <>
               "oom_killed=true, error=none, finished_at=2026-08-10T11:42:00Z"
  end

  @tag :docker
  test "reports a job container that stops during a command as a system failure" do
    attempt_id = "docker-stopped-#{System.unique_integer([:positive])}"

    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    resource = "robine-#{suffix}"

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      secrets: %{},
      steps: [%Step{name: "Stop container", kind: :run, value: "echo ready; sleep 30"}]
    }

    on_output = fn
      %{status: :running, content: "ready\n"} ->
        {_output, 0} = System.cmd("docker", ["kill", resource], stderr_to_stdout: true)
        :ok

      _event ->
        :ok
    end

    assert {:ok, result} = DockerRunner.run(specification, on_output)
    assert result.status == :failed
    assert result.reason == :system_failure
    assert [%{status: :failed, output: output}] = result.steps
    assert output =~ "Container stopped unexpectedly"
    assert output =~ "oom_killed=false"
    assert_resources_absent(attempt_id)
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
  test "runs failure and always steps after an ordinary failure and keeps skipped results" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-conditions-failure-#{System.unique_integer([:positive])}",
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      secrets: %{},
      steps: [
        %Step{name: "Primary", kind: :run, value: "printf primary; exit 7"},
        %Step{name: "Success only", kind: :run, value: "echo must-not-run"},
        %Step{name: "Failure handler", kind: :run, value: "printf handled", condition: :failure},
        %Step{
          name: "Cleanup",
          kind: :run,
          value: "printf cleanup-failed; exit 11",
          condition: :always
        }
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :failed
    assert result.reason == :command_failed

    assert [
             %{name: "Primary", status: :failed, exit_code: 7, output: "primary"},
             %{name: "Success only", status: :skipped, exit_code: nil},
             %{name: "Failure handler", status: :succeeded, output: "handled"},
             %{name: "Cleanup", status: :failed, exit_code: 11, output: "cleanup-failed"}
           ] = result.steps
  end

  @tag :docker
  test "skips failure steps on success and still runs always steps" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-conditions-success-#{System.unique_integer([:positive])}",
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      secrets: %{},
      steps: [
        %Step{name: "Primary", kind: :run, value: "printf ok"},
        %Step{name: "Failure only", kind: :run, value: "echo must-not-run", condition: :failure},
        %Step{name: "Cleanup", kind: :run, value: "printf cleaned", condition: :always}
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :succeeded

    assert [
             %{name: "Primary", status: :succeeded, output: "ok"},
             %{name: "Failure only", status: :skipped},
             %{name: "Cleanup", status: :succeeded, output: "cleaned"}
           ] = result.steps
  end

  @tag :docker
  test "treats an ordinary built-in failure as eligible for diagnostic steps" do
    specification = %Specification{
      version: 1,
      attempt_id: "docker-conditions-builtin-#{System.unique_integer([:positive])}",
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      secrets: %{},
      steps: [
        %Step{
          name: "Restore",
          kind: :builtin,
          value: "cache/restore",
          with: %{"key" => "fixture", "paths" => ["deps"]}
        },
        %Step{name: "Success only", kind: :run, value: "echo must-not-run"},
        %Step{name: "Diagnose", kind: :run, value: "printf diagnosed", condition: :failure}
      ]
    }

    callback = fn
      %{type: :builtin} -> {:error, :forced_restore_failure}
      _log_event -> :ok
    end

    assert {:ok, result} = DockerRunner.run(specification, callback)
    assert result.status == :failed

    assert [
             %{name: "Restore", status: :failed},
             %{name: "Success only", status: :skipped},
             %{name: "Diagnose", status: :succeeded, output: "diagnosed"}
           ] = result.steps
  end

  @tag :docker
  test "runs a private PostgreSQL service by DNS without host publication or workspace mount" do
    attempt_id = "docker-service-#{System.unique_integer([:positive])}"
    secret = "postgres-service-secret"

    service = %Service{
      id: "postgres",
      image: "postgres:18-alpine",
      user: "postgres",
      env: %{"POSTGRES_USER" => "robine", "POSTGRES_DB" => "app_test"},
      secret_env: %{"POSTGRES_PASSWORD" => secret},
      readiness: %{tcp: 5432, timeout_ms: 30_000}
    }

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 30_000,
      secrets: %{"TEST_DB_PASSWORD" => secret},
      services: [service],
      steps: [
        %Step{
          name: "Use PostgreSQL",
          kind: :run,
          value:
            "sleep 2; test ! -S /var/run/docker.sock; getent hosts postgres; PGPASSWORD=\"$TEST_DB_PASSWORD\" psql -h postgres -U robine -d app_test -Atc 'select 42'"
        }
      ]
    }

    owner = self()

    task =
      Task.async(fn ->
        DockerRunner.run(specification, fn event ->
          send(owner, {:service_event, event})
          :ok
        end)
      end)

    resource = docker_resource(attempt_id)
    service_resource = resource <> "-svc-postgres"
    wait_for_container!(service_resource)

    {ports, 0} = System.cmd("docker", ["port", service_resource], stderr_to_stdout: true)
    assert ports == ""

    {mounts_json, 0} =
      System.cmd(
        "docker",
        ["inspect", "--format", "{{json .Mounts}}", service_resource],
        stderr_to_stdout: true
      )

    mounts = Jason.decode!(mounts_json)
    refute Enum.any?(mounts, &(&1["Destination"] == "/workspace"))
    refute Enum.any?(mounts, &(&1["Source"] == "/var/run/docker.sock"))
    anonymous_volumes = for %{"Name" => name, "Type" => "volume"} <- mounts, do: name

    assert {:ok, result} = Task.await(task, 40_000)
    assert result.status == :succeeded, inspect(result)
    assert [%{output: output}] = result.steps
    assert output =~ "postgres"
    assert output =~ "42"
    refute inspect(result) =~ secret

    assert_received {:service_event,
                     %{
                       phase: :service_preparation,
                       step_name: "Service postgres",
                       status: :running
                     }}

    assert_received {:service_event,
                     %{
                       phase: :service_preparation,
                       step_name: "Service postgres",
                       status: :succeeded
                     }}

    assert_service_resources_absent(attempt_id, "postgres")
    assert Enum.all?(anonymous_volumes, &(docker_status(["volume", "inspect", &1]) == 1))
  end

  @tag :docker
  test "fails before user steps with a bounded redacted service diagnostic" do
    attempt_id = "docker-service-failure-#{System.unique_integer([:positive])}"
    secret = "service-diagnostic-secret"

    service = %Service{
      id: "broken",
      image: "alpine:3.22",
      secret_env: %{"TOKEN" => secret},
      command: ["/bin/sh", "-c", "printf '%s' \"$TOKEN\"; exit 2"],
      readiness: %{tcp: 43210, timeout_ms: 2_000}
    }

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 10_000,
      services: [service],
      steps: [%Step{name: "Never", kind: :run, value: "echo must-not-run"}]
    }

    assert {:error,
            {:docker, {:service_unavailable, "broken", {:service_exited, _status}, diagnostic}}} =
             DockerRunner.run(specification)

    assert diagnostic =~ "[REDACTED]"
    refute diagnostic =~ secret
    refute diagnostic =~ "must-not-run"
    assert byte_size(diagnostic) <= 64_000
    assert_service_resources_absent(attempt_id, "broken")
  end

  @tag :docker
  test "fails a running step when an already-ready service exits" do
    attempt_id = "docker-service-loss-#{System.unique_integer([:positive])}"

    service = %Service{
      id: "short_lived",
      image: "alpine:3.22",
      command: ["/bin/sh", "-c", "sleep 1; echo service-stopped; exit 3"]
    }

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 15_000,
      services: [service],
      steps: [
        %Step{name: "Wait", kind: :run, value: "echo step-started; sleep 10"},
        %Step{name: "Never", kind: :run, value: "echo must-not-run", condition: :always}
      ]
    }

    started = System.monotonic_time(:millisecond)
    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :failed
    assert result.reason == :service_unavailable
    assert [%{name: "Wait", output: output}] = result.steps
    assert output =~ "Service short_lived became unavailable"
    assert output =~ "service-stopped"
    refute output =~ "must-not-run"
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert_service_resources_absent(attempt_id, "short_lived")
  end

  @tag :docker
  test "cancels a service readiness wait and cleans its network" do
    attempt_id = "docker-service-cancel-#{System.unique_integer([:positive])}"

    service = %Service{
      id: "waiting",
      image: "alpine:3.22",
      command: ["sleep", "30"],
      readiness: %{tcp: 43210, timeout_ms: 30_000}
    }

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 30_000,
      services: [service],
      steps: [%Step{name: "Never", kind: :run, value: "echo must-not-run"}]
    }

    started = System.monotonic_time(:millisecond)
    cancel_requested = fn -> System.monotonic_time(:millisecond) - started > 500 end

    assert {:ok, %{status: :cancelled, steps: []}} =
             DockerRunner.run(specification, fn _event -> :ok end, cancel_requested)

    assert System.monotonic_time(:millisecond) - started < 5_000
    assert_service_resources_absent(attempt_id, "waiting")
  end

  @tag :docker
  test "times out service readiness before any user command" do
    attempt_id = "docker-service-timeout-#{System.unique_integer([:positive])}"

    service = %Service{
      id: "silent",
      image: "alpine:3.22",
      command: ["sleep", "30"],
      readiness: %{tcp: 43210, timeout_ms: 1_000}
    }

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 10_000,
      services: [service],
      steps: [%Step{name: "Never", kind: :run, value: "echo must-not-run"}]
    }

    assert {:error,
            {:docker, {:service_unavailable, "silent", {:readiness_timeout, 1_000}, diagnostic}}} =
             DockerRunner.run(specification)

    refute diagnostic =~ "must-not-run"
    assert byte_size(diagnostic) <= 64_000
    assert_service_resources_absent(attempt_id, "silent")
  end

  @tag :docker
  test "records default success steps as skipped after a command failure" do
    attempt_id = "docker-failure-#{System.unique_integer([:positive])}"

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
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

    assert [
             %{name: "Fail", status: :failed, exit_code: 7, output: "broken\n"},
             %{name: "Never", status: :skipped, exit_code: nil}
           ] = result.steps

    assert_resources_absent(attempt_id)
  end

  @tag :docker
  test "concurrent duplicate dispatch leaves the winning container owned and running" do
    attempt_id = "docker-duplicate-#{System.unique_integer([:positive])}"

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [%Step{name: "Winner", kind: :run, value: "sleep 2; printf winner"}]
    }

    tasks =
      for _index <- 1..2 do
        Task.async(fn -> DockerRunner.run(specification) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, %{status: :succeeded}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:docker, :duplicate_attempt}}, &1)) == 1

    assert [{:ok, result}] = Enum.filter(results, &match?({:ok, _result}, &1))
    assert [%{output: "winner"}] = result.steps

    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    assert docker_status(["container", "inspect", "robine-#{suffix}"]) == 1
    assert docker_status(["volume", "inspect", "robine-#{suffix}-workspace"]) == 1
  end

  @tag :docker
  test "separate jobs share no writable workspace and receive no Docker socket" do
    suffix = System.unique_integer([:positive])

    first = %Specification{
      version: 1,
      attempt_id: "isolation-first-#{suffix}",
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      steps: [%Step{name: "Write", kind: :run, value: "printf private > private-file"}]
    }

    second = %{
      first
      | attempt_id: "isolation-second-#{suffix}",
        steps: [
          %Step{
            name: "Inspect isolation",
            kind: :run,
            value: "test ! -e private-file && test ! -S /var/run/docker.sock && printf isolated"
          }
        ]
    }

    assert {:ok, %{status: :succeeded}} = DockerRunner.run(first)

    assert {:ok, %{status: :succeeded, steps: [%{output: "isolated"}]}} =
             DockerRunner.run(second)

    assert_resources_absent(first.attempt_id)
    assert_resources_absent(second.attempt_id)
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
  test "preserves stdout and stderr as separately sequenced channels" do
    parent = self()

    specification = %Specification{
      version: 1,
      attempt_id: "docker-channels-#{System.unique_integer([:positive])}",
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{},
      steps: [
        %Step{
          name: "Channels",
          kind: :run,
          value: "printf 'from-out\\n'; sleep 1; printf 'from-error\\n' >&2"
        }
      ]
    }

    assert {:ok, %{status: :succeeded}} =
             DockerRunner.run(specification, fn event ->
               send(parent, {:channel_event, event})
               :ok
             end)

    events = collect_channel_events([])
    running = Enum.filter(events, &(&1.step_name == "Channels" and &1.status == :running))

    assert Enum.any?(running, &(&1.stream == :stdout and &1.content =~ "from-out"))
    assert Enum.any?(running, &(&1.stream == :stderr and &1.content =~ "from-error"))
    assert Enum.map(running, & &1.sequence) == Enum.sort(Enum.map(running, & &1.sequence))
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
  test "redacts secrets embedded in builtin diagnostics" do
    secret = "builtin-diagnostic-secret"

    specification = %Specification{
      version: 1,
      attempt_id: "docker-builtin-diagnostic-#{System.unique_integer([:positive])}",
      image: "postgres:18-alpine",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      env: %{},
      secrets: %{"TOKEN" => secret},
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
      %{type: :builtin} -> {:error, {:storage_failure, secret}}
      _event -> :ok
    end

    assert {:ok, result} = DockerRunner.run(specification, callback)
    assert result.status == :failed
    assert [%{output: output}] = result.steps
    assert output =~ "[REDACTED]"
    refute inspect(result) =~ secret
  end

  @tag :docker
  test "reports a missing configured shell as a preparation failure" do
    attempt_id = "docker-shell-#{System.unique_integer([:positive])}"

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
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

    assert_resources_absent(attempt_id)
  end

  @tag :docker
  test "rejects an unsafe source after provisioning and cleans all owned resources" do
    attempt_id = "docker-source-failure-#{System.unique_integer([:positive])}"
    source = Path.join(System.tmp_dir!(), attempt_id)
    File.mkdir_p!(source)
    File.ln_s!("/etc/passwd", Path.join(source, "escape"))
    on_exit(fn -> File.rm_rf!(source) end)

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 20_000,
      source_path: source,
      env: %{},
      secrets: %{},
      steps: [%Step{name: "Never", kind: :run, value: "true"}]
    }

    assert {:error, {:docker, {:unsafe_source_tree, {:unsupported_file_type, :symlink, _path}}}} =
             DockerRunner.run(specification)

    assert_resources_absent(attempt_id)
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
    orphan_network = orphan_container <> "-network"
    active_network = active_container <> "-network"

    instance_label =
      "io.robine.instance=#{Application.fetch_env!(:robine, :runner_resource_namespace)}"

    on_exit(fn ->
      System.cmd("docker", ["rm", "--force", orphan_container], stderr_to_stdout: true)
      System.cmd("docker", ["rm", "--force", active_container], stderr_to_stdout: true)
      System.cmd("docker", ["volume", "rm", "--force", orphan_volume], stderr_to_stdout: true)
      System.cmd("docker", ["volume", "rm", "--force", active_volume], stderr_to_stdout: true)
      System.cmd("docker", ["network", "rm", orphan_network], stderr_to_stdout: true)
      System.cmd("docker", ["network", "rm", active_network], stderr_to_stdout: true)
    end)

    docker!([
      "create",
      "--name",
      orphan_container,
      "--label",
      "io.robine.attempt=#{orphan_attempt}",
      "--label",
      instance_label,
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
      "--label",
      instance_label,
      "alpine:3.22",
      "sleep",
      "3600"
    ])

    docker!([
      "volume",
      "create",
      "--label",
      "io.robine.attempt=#{orphan_attempt}",
      "--label",
      instance_label,
      orphan_volume
    ])

    docker!([
      "volume",
      "create",
      "--label",
      "io.robine.attempt=#{active_attempt}",
      "--label",
      instance_label,
      active_volume
    ])

    docker!([
      "network",
      "create",
      "--label",
      "io.robine.attempt=#{orphan_attempt}",
      "--label",
      instance_label,
      orphan_network
    ])

    docker!([
      "network",
      "create",
      "--label",
      "io.robine.attempt=#{active_attempt}",
      "--label",
      instance_label,
      active_network
    ])

    assert {:ok,
            %{
              containers_removed: containers,
              volumes_removed: volumes,
              networks_removed: networks
            }} =
             DockerRunner.reconcile_resources([active_attempt])

    assert containers >= 1
    assert volumes >= 1
    assert networks >= 1

    assert docker_status(["container", "inspect", orphan_container]) == 1
    assert docker_status(["volume", "inspect", orphan_volume]) == 1
    assert docker_status(["container", "inspect", active_container]) == 0
    assert docker_status(["volume", "inspect", active_volume]) == 0
    assert docker_status(["network", "inspect", orphan_network]) == 1
    assert docker_status(["network", "inspect", active_network]) == 0
  end

  @tag :docker
  test "does not reconcile resources owned by another Robine instance" do
    suffix = System.unique_integer([:positive])
    container = "robine-test-foreign-#{suffix}"

    on_exit(fn ->
      System.cmd("docker", ["rm", "--force", container], stderr_to_stdout: true)
    end)

    docker!([
      "create",
      "--name",
      container,
      "--label",
      "io.robine.attempt=foreign-attempt-#{suffix}",
      "--label",
      "io.robine.instance=foreign",
      "alpine:3.22",
      "sleep",
      "3600"
    ])

    assert {:ok, _counts} = DockerRunner.reconcile_resources([])
    assert docker_status(["container", "inspect", container]) == 0
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
        %Step{name: "Never", kind: :run, value: "echo should-not-run", condition: :always}
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

  @tag :docker
  test "times out the full container process tree and skips remaining steps" do
    previous = Application.fetch_env!(:robine, :runner_cancellation_grace_ms)
    Application.put_env(:robine, :runner_cancellation_grace_ms, 1_000)
    on_exit(fn -> Application.put_env(:robine, :runner_cancellation_grace_ms, previous) end)

    attempt_id = "docker-timeout-#{System.unique_integer([:positive])}"
    started = System.monotonic_time(:millisecond)

    specification = %Specification{
      version: 1,
      attempt_id: attempt_id,
      image: "alpine:3.22",
      workspace: "/workspace",
      shell: "/bin/sh",
      timeout_ms: 500,
      env: %{},
      secrets: %{},
      steps: [
        %Step{name: "Long", kind: :run, value: "trap '' TERM; sleep 30 & wait"},
        %Step{name: "Never", kind: :run, value: "echo should-not-run", condition: :always}
      ]
    }

    assert {:ok, result} = DockerRunner.run(specification)
    assert result.status == :failed
    assert result.reason == :timeout
    assert [%{name: "Long", status: :timed_out, output: output}] = result.steps
    assert output =~ "command timed out"
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

  defp collect_channel_events(events) do
    receive do
      {:channel_event, event} -> collect_channel_events([event | events])
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

  defp assert_resources_absent(attempt_id) do
    resource = docker_resource(attempt_id)
    assert docker_status(["container", "inspect", resource]) == 1
    assert docker_status(["volume", "inspect", resource <> "-workspace"]) == 1
  end

  defp assert_service_resources_absent(attempt_id, service_id) do
    resource = docker_resource(attempt_id)
    assert_resources_absent(attempt_id)
    assert docker_status(["container", "inspect", "#{resource}-svc-#{service_id}"]) == 1
    assert docker_status(["network", "inspect", resource <> "-network"]) == 1
  end

  defp docker_resource(attempt_id) do
    suffix =
      :crypto.hash(:sha256, attempt_id) |> Base.encode16(case: :lower) |> binary_part(0, 20)

    "robine-#{suffix}"
  end

  defp wait_for_container!(resource, attempts \\ 100)
  defp wait_for_container!(resource, 0), do: flunk("container #{resource} did not appear")

  defp wait_for_container!(resource, attempts) do
    if docker_status(["container", "inspect", resource]) == 0 do
      :ok
    else
      receive do
      after
        50 -> wait_for_container!(resource, attempts - 1)
      end
    end
  end
end
