defmodule Robine.Adapters.Runner.RemoteClientTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Runner.RemoteClient

  test "builds only TLS or explicit loopback socket URLs" do
    assert RemoteClient.socket_url("https://ci.example.test/base") ==
             {:ok, "wss://ci.example.test/runner/socket/websocket?vsn=2.0.0"}

    assert RemoteClient.socket_url("http://localhost:4000") ==
             {:ok, "ws://localhost:4000/runner/socket/websocket?vsn=2.0.0"}

    assert {:error, :tls_required} = RemoteClient.socket_url("http://ci.example.test")
    assert {:error, :tls_required} = RemoteClient.socket_url("ftp://ci.example.test")
  end

  test "uses bounded exponential backoff with injectable full jitter" do
    minimum = fn _ceiling -> 1 end
    maximum = fn ceiling -> ceiling end

    assert RemoteClient.reconnect_delay(1, minimum) == 0
    assert RemoteClient.reconnect_delay(1, maximum) == 500 - 1
    assert RemoteClient.reconnect_delay(10, maximum) == 30_000 - 1
    assert RemoteClient.reconnect_delay(30, maximum) == 30_000 - 1
  end

  test "emits a Phoenix join without placing credentials in the frame and redacts status" do
    state = state()

    assert {:ok, connected} = RemoteClient.handle_connect(%{}, state)
    assert_receive :join_runner_channel

    assert {:reply, {:text, encoded}, ^connected} =
             RemoteClient.handle_info(:join_runner_channel, connected)

    assert {:ok, ["1", "1", "runner:v1", "phx_join", hello]} = Jason.decode(encoded)
    assert hello["supported_protocol_versions"] == [1]
    assert hello["active_attempt_ids"] == ["attempt-1"]
    assert hello["active_deployment_ids"] == ["deployment-1"]
    refute encoded =~ state.credential

    status = RemoteClient.format_status(:normal, [[], connected])
    assert status.credential == "[REDACTED]"
    refute inspect(status) =~ state.credential
  end

  test "accepts a bounded welcome and sends sequenced attempt events" do
    state = state()

    welcome =
      Jason.encode!([
        "1",
        "1",
        "runner:v1",
        "phx_reply",
        %{
          "status" => "ok",
          "response" => %{"heartbeat_interval_seconds" => 20, "resume" => []}
        }
      ])

    assert {:ok, ready} = RemoteClient.handle_frame({:text, welcome}, state)
    assert ready.joined?

    event = %{
      "idempotency_token" => Ecto.UUID.generate(),
      "message_id" => Ecto.UUID.generate(),
      "sequence" => 1,
      "status" => "preparing"
    }

    assert {:reply, {:text, encoded}, updated} =
             RemoteClient.handle_cast({:attempt_event, event}, ready)

    assert {:ok, ["1", "2", "runner:v1", "attempt_event", ^event]} = Jason.decode(encoded)
    assert updated.next_reference == 3
  end

  test "queues durable attempt events while disconnected and replays them after joining" do
    state = state(%{joined?: false, next_reference: 9})

    event = %{
      "attempt_id" => Ecto.UUID.generate(),
      "sequence" => 3,
      "status" => "succeeded"
    }

    assert {:ok, queued} = RemoteClient.handle_cast({:attempt_event, event}, state)
    assert queued.pending_events == %{"9" => event}
    assert_receive {:runner_event, :queued_for_reconnect, attempt_id}
    assert attempt_id == event["attempt_id"]

    assert {:ok, _ready} =
             RemoteClient.handle_frame(
               {:text,
                Jason.encode!([
                  "1",
                  "1",
                  "runner:v1",
                  "phx_reply",
                  %{
                    "status" => "ok",
                    "response" => %{"heartbeat_interval_seconds" => 20}
                  }
                ])},
               queued
             )

    assert_receive {:replay_attempt_event, "9", ^event}
  end

  test "forwards cancellation requests returned by a heartbeat" do
    state = %{state() | joined?: true}

    reply =
      Jason.encode!([
        "1",
        "9",
        "runner:v1",
        "phx_reply",
        %{
          "status" => "ok",
          "response" => %{"cancellation_requested_attempt_ids" => ["attempt-1"]}
        }
      ])

    assert {:ok, ^state} = RemoteClient.handle_frame({:text, reply}, state)
    assert_receive {:runner_message, "cancel", %{"attempt_id" => "attempt-1"}}
  end

  test "durably accepts a job offer before exposing it to the executor" do
    state = %{state() | joined?: true, active_attempt_ids: []}

    offer = %{
      "attempt_id" => "attempt-2",
      "idempotency_token" => "token-2",
      "execution" => %{}
    }

    frame = Jason.encode!([nil, "server-1", "runner:v1", "job_offer", offer])

    assert {:reply, {:text, acceptance_frame}, accepting} =
             RemoteClient.handle_frame({:text, frame}, state)

    assert {:ok, ["1", reference, "runner:v1", "job_accept", acceptance]} =
             Jason.decode(acceptance_frame)

    assert acceptance["attempt_id"] == "attempt-2"
    assert acceptance["idempotency_token"] == "token-2"
    assert is_binary(acceptance["message_id"])
    refute_received {:runner_message, "job_offer", _offer}

    reply =
      Jason.encode!([
        "1",
        reference,
        "runner:v1",
        "phx_reply",
        %{"status" => "ok", "response" => %{"acknowledged_sequence" => 1}}
      ])

    assert {:ok, accepted} = RemoteClient.handle_frame({:text, reply}, accepting)
    assert accepted.pending_offers == %{}
    assert_receive {:runner_message, "job_offer", ^offer}
  end

  test "durably accepts and replays deployment offers and events" do
    state = %{state() | joined?: true, active_deployment_ids: []}

    offer = %{
      "deployment_id" => "deployment-2",
      "idempotency_token" => "deployment-token-2",
      "kind" => "application"
    }

    frame = Jason.encode!([nil, "server-2", "runner:v1", "deployment_offer", offer])

    assert {:reply, {:text, acceptance_frame}, accepting} =
             RemoteClient.handle_frame({:text, frame}, state)

    assert {:ok, ["1", reference, "runner:v1", "deployment_accept", acceptance]} =
             Jason.decode(acceptance_frame)

    assert acceptance["deployment_id"] == "deployment-2"
    assert acceptance["idempotency_token"] == "deployment-token-2"
    refute_received {:runner_message, "deployment_offer", _offer}

    reply =
      Jason.encode!([
        "1",
        reference,
        "runner:v1",
        "phx_reply",
        %{"status" => "ok", "response" => %{"acknowledged_sequence" => 1}}
      ])

    assert {:ok, accepted} = RemoteClient.handle_frame({:text, reply}, accepting)
    assert_receive {:runner_message, "deployment_offer", ^offer}

    event = %{
      "deployment_id" => "deployment-2",
      "idempotency_token" => "deployment-token-2",
      "message_id" => Ecto.UUID.generate(),
      "sequence" => 2,
      "status" => "converging_services"
    }

    assert {:reply, {:text, event_frame}, pending} =
             RemoteClient.handle_cast({:deployment_event, event}, accepted)

    assert {:ok, ["1", event_reference, "runner:v1", "deployment_event", ^event]} =
             Jason.decode(event_frame)

    disconnected = %{pending | joined?: false}
    assert {:ok, _ready} = RemoteClient.handle_frame({:text, welcome_frame()}, disconnected)
    assert_receive {:replay_deployment_event, ^event_reference, ^event}
  end

  test "forwards immediate revocation cancellation to the runner supervisor" do
    state = %{state() | joined?: true}

    frame =
      Jason.encode!([
        nil,
        "server-revoke",
        "runner:v1",
        "runner_revoked",
        %{"cancel_active_attempts" => true}
      ])

    assert {:ok, ^state} = RemoteClient.handle_frame({:text, frame}, state)

    assert_receive {:runner_message, "runner_revoked", %{"cancel_active_attempts" => true}}
  end

  defp state do
    %{
      runner_id: Ecto.UUID.generate(),
      credential: "rrc_top-secret",
      software_version: "0.2.0-dev",
      supported_protocol_versions: [1],
      capabilities: %{"docker" => true},
      active_attempt_ids: ["attempt-1"],
      active_deployment_ids: ["deployment-1"],
      pending_events: %{},
      pending_deployment_events: %{},
      pending_offers: %{},
      owner: self(),
      reconnect_attempt: 0,
      jitter: fn ceiling -> ceiling end,
      next_reference: 2,
      heartbeat_seconds: 20,
      joined?: false
    }
  end

  defp state(overrides), do: Map.merge(state(), overrides)

  defp welcome_frame do
    Jason.encode!([
      "1",
      "1",
      "runner:v1",
      "phx_reply",
      %{
        "status" => "ok",
        "response" => %{"heartbeat_interval_seconds" => 20, "resume" => []}
      }
    ])
  end
end
