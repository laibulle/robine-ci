defmodule Robine.Adapters.Execution.NativeRunnerTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Execution.NativeRunner
  alias Robine.Execution.Contracts.{Specification, Step}

  test "runs sequential host steps in an isolated workspace and redacts secrets" do
    source = temporary_source(%{"input.txt" => "native"})
    owner = self()

    specification =
      specification(source, [
        %Step{name: "Build", kind: :run, value: "printf '%s' \"$TOKEN\" > result.txt"},
        %Step{
          name: "Verify",
          kind: :run,
          value: "printf '%s:%s' \"$(cat input.txt)\" \"$(cat result.txt)\""
        }
      ])

    assert {:ok, result} =
             NativeRunner.run(specification, &send(owner, {:event, &1}), fn -> false end)

    assert result.status == :succeeded
    assert Enum.at(result.steps, 1).output == "native:[REDACTED]"
    refute inspect(drain_events([])) =~ "macos-secret"

    assert Path.wildcard(
             Path.join(System.tmp_dir!(), "robine-native-#{specification.attempt_id}-*")
           ) == []
  end

  test "returns command failures without running later success-only steps" do
    specification =
      specification(nil, [
        %Step{name: "Fail", kind: :run, value: "exit 7"},
        %Step{name: "Skipped", kind: :run, value: "touch must-not-exist"}
      ])

    assert {:ok, result} = NativeRunner.run(specification, fn _ -> :ok end, fn -> false end)
    assert result.status == :failed
    assert result.reason == :command_failed
    assert Enum.map(result.steps, & &1.status) == [:failed, :skipped]
  end

  test "cancels an active host process" do
    cancellation = :atomics.new(1, signed: false)
    specification = specification(nil, [%Step{name: "Wait", kind: :run, value: "sleep 10"}])
    owner = self()

    task =
      Task.async(fn ->
        NativeRunner.run(specification, &send(owner, {:event, &1}), fn ->
          :atomics.get(cancellation, 1) == 1
        end)
      end)

    assert_receive {:event, %{status: :running}}, 2_000
    :atomics.put(cancellation, 1, 1)
    assert {:ok, %{status: :cancelled}} = Task.await(task, 3_000)
  end

  test "publishes and restores caches and artifacts in the native workspace" do
    {:ok, store} = Agent.start_link(fn -> %{} end)

    steps = [
      %Step{
        name: "Create",
        kind: :run,
        value: "mkdir cache reports; echo cached > cache/value; echo report > reports/value"
      },
      %Step{
        name: "Save cache",
        kind: :builtin,
        value: "cache/save",
        with: %{"key" => "native-v1", "paths" => ["cache"]}
      },
      %Step{
        name: "Upload artifact",
        kind: :builtin,
        value: "artifacts/upload",
        with: %{"name" => "reports", "paths" => ["reports"], "retention-days" => 7}
      },
      %Step{name: "Clear", kind: :run, value: "rm -rf cache reports"},
      %Step{
        name: "Restore cache",
        kind: :builtin,
        value: "cache/restore",
        with: %{"key" => "native-v1", "paths" => ["cache"]}
      },
      %Step{
        name: "Download artifact",
        kind: :builtin,
        value: "artifacts/download",
        with: %{"name" => "reports", "from" => "build", "path" => "."}
      },
      %Step{
        name: "Verify",
        kind: :run,
        value: "test \"$(cat cache/value)\" = cached && test \"$(cat reports/value)\" = report"
      }
    ]

    callback = fn
      %{type: :builtin, phase: :publish, builtin: builtin, content: content} ->
        Agent.update(store, &Map.put(&1, builtin, content))
        {:ok, %{size: byte_size(content)}}

      %{type: :builtin, phase: :restore, builtin: "cache/restore"} ->
        {:ok, %{content: Agent.get(store, & &1["cache/save"])}}

      %{type: :builtin, phase: :restore, builtin: "artifacts/download"} ->
        {:ok, %{content: Agent.get(store, & &1["artifacts/upload"])}}

      _log_event ->
        :ok
    end

    assert {:ok, result} = NativeRunner.run(specification(nil, steps), callback, fn -> false end)
    assert result.status == :succeeded
    assert Enum.all?(result.steps, &(&1.status == :succeeded))
  end

  defp specification(source, steps) do
    %Specification{
      version: 1,
      attempt_id: Ecto.UUID.generate(),
      image: "native",
      workspace: "/workspace",
      shell: "/bin/sh",
      steps: steps,
      timeout_ms: 5_000,
      source_path: source,
      secrets: %{"TOKEN" => "macos-secret"}
    }
  end

  defp temporary_source(files) do
    directory =
      Path.join(System.tmp_dir!(), "robine-native-source-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    Enum.each(files, fn {path, body} -> File.write!(Path.join(directory, path), body) end)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp drain_events(events) do
    receive do
      {:event, event} -> drain_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
