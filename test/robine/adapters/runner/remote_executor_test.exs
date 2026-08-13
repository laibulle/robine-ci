defmodule Robine.Adapters.Runner.RemoteExecutorTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.Runner.RemoteExecutor

  defmodule FakeTransfer do
    def download_source(_url, _config), do: {:ok, nil}
    def download_secrets(_url, _config), do: {:ok, %{"TOKEN" => "remote-secret-value"}}
  end

  defmodule FakeRequest do
    def request(method, url, headers, body, config) do
      send(config[:test_owner], {:transfer_request, method, url, headers})
      store = config[:transfer_store]

      case {method, URI.parse(url).path} do
        {:put, path} when is_binary(path) ->
          key = if String.ends_with?(path, "/cache"), do: :cache, else: :artifact
          Agent.update(store, &Map.put(&1, key, body))
          {:ok, 201, ~s({"size":1})}

        {:get, path} when is_binary(path) ->
          key = if String.ends_with?(path, "/cache"), do: :cache, else: :artifact

          case Agent.get(store, &Map.get(&1, key)) do
            nil -> {:ok, 204, ""}
            content -> {:ok, 200, content}
          end
      end
    end
  end

  @tag :docker
  test "runs an offered Docker job and emits ordered redacted protocol events" do
    client = fake_client(self())
    attempt_id = Ecto.UUID.generate()
    token = Ecto.UUID.generate()

    offer = %{
      "attempt_id" => attempt_id,
      "idempotency_token" => token,
      "source_url" => nil,
      "secrets_url" => "https://ci.example.test/secrets",
      "execution" => %{
        "attempt_id" => attempt_id,
        "idempotency_token" => token,
        "image" => "alpine:3.22",
        "shell" => "/bin/sh",
        "timeout_ms" => 20_000,
        "env" => %{"ROBINE_MATRIX_VERSION" => "3.22"},
        "base_id" => "test",
        "matrix_values" => %{"version" => "3.22"},
        "secret_names" => ["TOKEN"],
        "steps" => [
          %{
            "name" => "Remote",
            "kind" => "run",
            "value" => "printf '%s:%s' \"$TOKEN\" \"$ROBINE_MATRIX_VERSION\"",
            "with" => %{}
          }
        ]
      }
    }

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_test",
      transfer_adapter: FakeTransfer
    }

    assert :ok = RemoteExecutor.run(offer, client, config)

    assert_receive {:attempt_event, %{"sequence" => 2, "status" => "running"}}

    messages = drain_messages([])

    assert Enum.any?(messages, fn
             {:log_event, %{"content" => content}} -> content == "[REDACTED]:3.22"
             _message -> false
           end)

    refute inspect(messages) =~ "remote-secret-value"

    assert Enum.any?(messages, fn
             {:attempt_event, %{"sequence" => 3, "status" => "succeeded"}} -> true
             _message -> false
           end)
  end

  test "runs an offered job through the native host executor" do
    client = fake_client(self())
    attempt_id = Ecto.UUID.generate()
    token = Ecto.UUID.generate()

    offer = %{
      "attempt_id" => attempt_id,
      "idempotency_token" => token,
      "source_url" => nil,
      "secrets_url" => "https://ci.example.test/secrets",
      "execution" => %{
        "attempt_id" => attempt_id,
        "idempotency_token" => token,
        "image" => "native",
        "shell" => "/bin/sh",
        "timeout_ms" => 5_000,
        "env" => %{},
        "secret_names" => ["TOKEN"],
        "steps" => [
          %{
            "name" => "Native",
            "kind" => "run",
            "value" => "printf 'host:%s' \"$TOKEN\"",
            "with" => %{}
          }
        ]
      }
    }

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_test",
      "executor" => "native",
      transfer_adapter: FakeTransfer
    }

    assert :ok = RemoteExecutor.run(offer, client, config)
    messages = drain_messages([])

    assert Enum.any?(messages, fn
             {:log_event, %{"content" => "host:[REDACTED]"}} -> true
             _message -> false
           end)

    assert Enum.any?(messages, fn
             {:attempt_event, %{"sequence" => 3, "status" => "succeeded"}} -> true
             _message -> false
           end)
  end

  @tag :docker
  test "evaluates the same conditional step contract on a remote runner" do
    client = fake_client(self())
    attempt_id = Ecto.UUID.generate()
    token = Ecto.UUID.generate()

    offer = %{
      "attempt_id" => attempt_id,
      "idempotency_token" => token,
      "source_url" => nil,
      "secrets_url" => "https://ci.example.test/secrets",
      "execution" => %{
        "attempt_id" => attempt_id,
        "idempotency_token" => token,
        "image" => "alpine:3.22",
        "shell" => "/bin/sh",
        "timeout_ms" => 20_000,
        "env" => %{},
        "secret_names" => [],
        "steps" => [
          %{
            "name" => "Primary",
            "kind" => "run",
            "value" => "printf remote-primary; exit 9",
            "condition" => "success",
            "with" => %{}
          },
          %{
            "name" => "Success only",
            "kind" => "run",
            "value" => "echo must-not-run",
            "condition" => "success",
            "with" => %{}
          },
          %{
            "name" => "Diagnostic",
            "kind" => "run",
            "value" => "printf remote-diagnostic",
            "condition" => "failure",
            "with" => %{}
          }
        ]
      }
    }

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_test",
      transfer_adapter: FakeTransfer
    }

    assert :ok = RemoteExecutor.run(offer, client, config)
    messages = drain_messages([])

    assert Enum.any?(messages, fn
             {:log_event, %{"step_name" => "Success only", "status" => "skipped"}} -> true
             _message -> false
           end)

    assert Enum.any?(messages, fn
             {:log_event, %{"step_name" => "Diagnostic", "content" => "remote-diagnostic"}} ->
               true

             _message ->
               false
           end)

    assert Enum.any?(messages, fn
             {:attempt_event,
              %{"sequence" => 3, "status" => "failed", "reason" => "command_failed"}} ->
               true

             _message ->
               false
           end)
  end

  @tag :docker
  test "stops the Docker job when the control plane requests cancellation" do
    previous_grace = Application.fetch_env!(:robine, :runner_cancellation_grace_ms)
    Application.put_env(:robine, :runner_cancellation_grace_ms, 1_000)

    on_exit(fn ->
      Application.put_env(:robine, :runner_cancellation_grace_ms, previous_grace)
    end)

    client = fake_client(self())
    attempt_id = Ecto.UUID.generate()
    token = Ecto.UUID.generate()

    offer = %{
      "attempt_id" => attempt_id,
      "idempotency_token" => token,
      "source_url" => nil,
      "secrets_url" => "https://ci.example.test/secrets",
      "execution" => %{
        "attempt_id" => attempt_id,
        "idempotency_token" => token,
        "image" => "alpine:3.22",
        "shell" => "/bin/sh",
        "timeout_ms" => 20_000,
        "env" => %{},
        "secret_names" => [],
        "steps" => [
          %{"name" => "Wait", "kind" => "run", "value" => "sleep 10", "with" => %{}}
        ]
      }
    }

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_test",
      transfer_adapter: FakeTransfer
    }

    owner = self()

    executor =
      spawn(fn -> send(owner, {:execution_result, RemoteExecutor.run(offer, client, config)}) end)

    assert_receive {:attempt_event, %{"sequence" => 2, "status" => "running"}}
    send(executor, :cancel_requested)

    assert_receive {:attempt_event, %{"sequence" => 3, "status" => "cancelled"}}, 5_000
    assert_receive {:execution_result, :ok}
  end

  @tag :docker
  test "publishes and restores caches and artifacts through authenticated transfers" do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    client = fake_client(self())
    attempt_id = Ecto.UUID.generate()

    offer = %{
      "attempt_id" => attempt_id,
      "idempotency_token" => Ecto.UUID.generate(),
      "source_url" => nil,
      "secrets_url" => "https://ci.example.test/secrets",
      "builtins_url" => "https://ci.example.test/api/v1/runners/attempts/#{attempt_id}",
      "execution" => %{
        "attempt_id" => attempt_id,
        "idempotency_token" => Ecto.UUID.generate(),
        "pipeline_id" => Ecto.UUID.generate(),
        "repository_id" => Ecto.UUID.generate(),
        "needs" => ["build"],
        "image" => "alpine:3.22",
        "shell" => "/bin/sh",
        "timeout_ms" => 20_000,
        "env" => %{},
        "secret_names" => [],
        "steps" => [
          %{
            "name" => "Create",
            "kind" => "run",
            "value" =>
              "mkdir -p deps reports; echo cache > deps/value; echo artifact > reports/value",
            "with" => %{}
          },
          %{
            "name" => "Save cache",
            "kind" => "builtin",
            "value" => "cache/save",
            "with" => %{"key" => "deps-v1", "paths" => ["deps"]}
          },
          %{
            "name" => "Upload",
            "kind" => "builtin",
            "value" => "artifacts/upload",
            "with" => %{"name" => "reports", "paths" => ["reports"], "retention-days" => 7}
          },
          %{
            "name" => "Clear",
            "kind" => "run",
            "value" => "rm -rf deps reports",
            "with" => %{}
          },
          %{
            "name" => "Restore cache",
            "kind" => "builtin",
            "value" => "cache/restore",
            "with" => %{"key" => "deps-v1", "paths" => ["deps"]}
          },
          %{
            "name" => "Download",
            "kind" => "builtin",
            "value" => "artifacts/download",
            "with" => %{"name" => "reports", "from" => "build", "path" => "."}
          },
          %{
            "name" => "Verify",
            "kind" => "run",
            "value" =>
              "test \"$(cat deps/value)\" = cache && test \"$(cat reports/value)\" = artifact",
            "with" => %{}
          }
        ]
      }
    }

    config = %{
      "runner_id" => Ecto.UUID.generate(),
      "credential" => "rrc_test",
      transfer_adapter: FakeTransfer,
      request_adapter: FakeRequest,
      transfer_store: store,
      test_owner: self()
    }

    assert :ok = RemoteExecutor.run(offer, client, config)
    messages = drain_messages([])

    assert Enum.any?(messages, fn
             {:attempt_event, %{"sequence" => 3, "status" => "succeeded"}} -> true
             _message -> false
           end)

    requests =
      for {:transfer_request, method, url, headers} <- messages, do: {method, url, headers}

    assert length(requests) == 4

    assert Enum.all?(requests, fn {_method, _url, headers} ->
             {"authorization", "Bearer rrc_test"} in headers
           end)
  end

  defp fake_client(owner) do
    spawn(fn -> fake_client_loop(owner) end)
  end

  defp fake_client_loop(owner) do
    receive do
      {:"$websockex_cast", {event, payload}} when event in [:attempt_event, :log_event] ->
        send(owner, {event, payload})
        fake_client_loop(owner)

      {:"$websockex_send", from, {:text, encoded}} ->
        {:ok, [_join_ref, _reference, "runner:v1", event, payload]} = Jason.decode(encoded)
        send(owner, {String.to_existing_atom(event), payload})
        :gen.reply(from, :ok)
        fake_client_loop(owner)
    end
  end

  defp drain_messages(messages) do
    receive do
      message -> drain_messages([message | messages])
    after
      50 -> Enum.reverse(messages)
    end
  end
end
