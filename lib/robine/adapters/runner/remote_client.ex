defmodule Robine.Adapters.Runner.RemoteClient do
  @moduledoc "Outbound Phoenix-channel client used by the standalone remote runner."

  use WebSockex

  @topic "runner:v1"
  @join_ref "1"
  @max_backoff_ms 30_000

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(options) do
    with {:ok, state} <- initial_state(options),
         {:ok, url} <- socket_url(Keyword.fetch!(options, :server_url)) do
      WebSockex.start_link(
        url,
        __MODULE__,
        state,
        (connection_options(state, url) ++
           [async: true, handle_initial_conn_failure: true, name: Keyword.get(options, :name)])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      )
    end
  end

  @spec send_attempt_event(pid(), map()) :: :ok
  def send_attempt_event(client, event), do: WebSockex.cast(client, {:attempt_event, event})

  @spec send_log_event(pid(), map()) :: :ok | {:error, term()}
  def send_log_event(client, event) do
    reference = Ecto.UUID.generate()
    encoded = Jason.encode!(channel_message(reference, "log_event", event))

    if byte_size(encoded) <= 262_144 do
      retry_log_frame(client, encoded, System.monotonic_time(:millisecond) + 30_000)
    else
      {:error, :log_event_too_large}
    end
  end

  defp retry_log_frame(client, encoded, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :log_delivery_timeout}
    else
      case safe_send_frame(client, encoded, min(remaining, 1_000)) do
        :ok ->
          :ok

        {:error, _reason} ->
          receive do
          after
            min(50, remaining) -> retry_log_frame(client, encoded, deadline)
          end
      end
    end
  end

  defp safe_send_frame(client, encoded, timeout) do
    WebSockex.send_frame(client, {:text, encoded}, timeout)
  catch
    :exit, _reason -> {:error, :runner_client_unavailable}
  end

  @impl true
  def handle_connect(_connection, state) do
    notify(state, {:runner_connection, :connected})
    send(self(), :join_runner_channel)
    {:ok, %{state | reconnect_attempt: 0, joined?: false}}
  end

  @impl true
  def handle_disconnect(status, state) do
    attempt = state.reconnect_attempt + 1
    delay = reconnect_delay(attempt, state.jitter)
    notify(state, {:runner_connection, :disconnected, status.reason, delay})

    receive do
    after
      delay -> :ok
    end

    {:reconnect, %{state | reconnect_attempt: attempt, joined?: false}}
  end

  @impl true
  def handle_frame({:text, encoded}, state) when byte_size(encoded) <= 262_144 do
    case Jason.decode(encoded) do
      {:ok, [@join_ref, "1", @topic, "phx_reply", %{"status" => "ok", "response" => welcome}]} ->
        interval = welcome["heartbeat_interval_seconds"] || 20
        schedule_heartbeat(interval)
        replay_pending(state.pending_events)
        replay_pending_offers(state.pending_offers)
        notify(state, {:runner_connection, :ready, welcome})
        {:ok, %{state | joined?: true, heartbeat_seconds: interval}}

      {:ok, [_join_ref, reference, @topic, "phx_reply", reply]} ->
        notify_cancellations(reply, state)
        notify(state, {:runner_reply, reference, reply})
        state = acknowledge_offer(reference, reply, state)
        {:ok, acknowledge_pending(reference, reply, state)}

      {:ok, [_join_ref, _reference, @topic, "job_offer", %{"attempt_id" => attempt_id} = offer]} ->
        if attempt_id in state.active_attempt_ids do
          notify(state, {:runner_message, "duplicate_job_offer", %{"attempt_id" => attempt_id}})
          {:ok, state}
        else
          {reference, state} = next_reference(state)

          acceptance = %{
            "attempt_id" => attempt_id,
            "idempotency_token" => offer["idempotency_token"],
            "message_id" => Ecto.UUID.generate()
          }

          state = %{
            state
            | active_attempt_ids: [attempt_id | state.active_attempt_ids],
              pending_offers:
                Map.put(state.pending_offers, reference, %{offer: offer, acceptance: acceptance})
          }

          {:reply, text_frame(channel_message(reference, "job_accept", acceptance)), state}
        end

      {:ok, [_join_ref, _reference, @topic, event, payload]} ->
        notify(state, {:runner_message, event, payload})
        {:ok, state}

      _invalid ->
        {:close, {1002, "invalid Phoenix frame"}, state}
    end
  end

  def handle_frame({:text, _oversized}, state),
    do: {:close, {1009, "message too large"}, state}

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:attempt_event, event}, %{joined?: true} = state) do
    {reference, state} = next_reference(state)
    state = %{state | pending_events: Map.put(state.pending_events, reference, event)}
    {:reply, text_frame(channel_message(reference, "attempt_event", event)), state}
  end

  def handle_cast({:attempt_event, event}, state) do
    {reference, state} = next_reference(state)
    notify(state, {:runner_event, :queued_for_reconnect, event["attempt_id"]})
    {:ok, %{state | pending_events: Map.put(state.pending_events, reference, event)}}
  end

  def handle_cast({:log_event, event}, %{joined?: true} = state) do
    {reference, state} = next_reference(state)
    {:reply, text_frame(channel_message(reference, "log_event", event)), state}
  end

  def handle_cast({:log_event, _event}, state) do
    notify(state, {:runner_error, :not_connected})
    {:ok, state}
  end

  @impl true
  def handle_info(:join_runner_channel, state) do
    {:reply, text_frame(join_message(state)), state}
  end

  def handle_info(:heartbeat, %{joined?: true} = state) do
    {reference, state} = next_reference(state)
    schedule_heartbeat(state.heartbeat_seconds)
    {:reply, text_frame(channel_message(reference, "heartbeat", %{})), state}
  end

  def handle_info(:heartbeat, state), do: {:ok, state}

  def handle_info({:replay_attempt_event, reference, event}, %{joined?: true} = state) do
    {:reply, text_frame(channel_message(reference, "attempt_event", event)), state}
  end

  def handle_info({:replay_attempt_event, _reference, _event}, state), do: {:ok, state}

  def handle_info({:replay_job_accept, reference, acceptance}, %{joined?: true} = state) do
    {:reply, text_frame(channel_message(reference, "job_accept", acceptance)), state}
  end

  def handle_info({:replay_job_accept, _reference, _acceptance}, state), do: {:ok, state}

  @impl true
  def format_status(_reason, [_process_dictionary, state]) do
    state |> Map.put(:credential, "[REDACTED]") |> Map.put(:owner, inspect(state.owner))
  end

  @doc false
  def socket_url(server_url) when is_binary(server_url) do
    uri = URI.parse(server_url)

    scheme =
      case uri.scheme do
        "https" -> "wss"
        "http" when uri.host in ["localhost", "127.0.0.1", "::1"] -> "ws"
        _unsupported -> nil
      end

    if scheme && is_binary(uri.host) do
      {:ok,
       %URI{uri | scheme: scheme, path: "/runner/socket/websocket", query: "vsn=2.0.0"}
       |> URI.to_string()}
    else
      {:error, :tls_required}
    end
  end

  def socket_url(_server_url), do: {:error, :invalid_server_url}

  @doc false
  def reconnect_delay(attempt, jitter_fun \\ &:rand.uniform/1)
      when is_integer(attempt) and attempt > 0 and is_function(jitter_fun, 1) do
    ceiling = min(round(:math.pow(2, min(attempt, 15))) * 250, @max_backoff_ms)
    jitter_fun.(max(ceiling, 1)) - 1
  end

  defp initial_state(options) do
    with {:ok, runner_id} <- Keyword.fetch(options, :runner_id),
         {:ok, credential} <- Keyword.fetch(options, :credential),
         true <- is_binary(runner_id) and is_binary(credential) do
      {:ok,
       %{
         runner_id: runner_id,
         credential: credential,
         software_version: Keyword.get(options, :software_version, "0.1.0"),
         supported_protocol_versions: Keyword.get(options, :supported_protocol_versions, [1]),
         capabilities: Keyword.get(options, :capabilities, default_capabilities()),
         active_attempt_ids: Keyword.get(options, :active_attempt_ids, []),
         pending_events: %{},
         pending_offers: %{},
         owner: Keyword.get(options, :owner, self()),
         reconnect_attempt: 0,
         jitter: Keyword.get(options, :jitter, &:rand.uniform/1),
         next_reference: 2,
         heartbeat_seconds: 20,
         joined?: false
       }}
    else
      _invalid -> {:error, :invalid_runner_credentials}
    end
  end

  defp connection_options(state, "wss://" <> _rest) do
    [
      extra_headers: headers(state),
      insecure: false,
      cacerts: :public_key.cacerts_get()
    ]
  end

  defp connection_options(state, "ws://" <> _rest), do: [extra_headers: headers(state)]

  defp headers(state) do
    [
      {"x-robine-runner-id", state.runner_id},
      {"x-robine-runner-credential", state.credential}
    ]
  end

  defp join_message(state) do
    [
      @join_ref,
      "1",
      @topic,
      "phx_join",
      %{
        "supported_protocol_versions" => state.supported_protocol_versions,
        "software_version" => state.software_version,
        "capabilities" => state.capabilities,
        "active_attempt_ids" => state.active_attempt_ids
      }
    ]
  end

  defp channel_message(reference, event, payload),
    do: [@join_ref, reference, @topic, event, payload]

  defp text_frame(message), do: {:text, Jason.encode!(message)}

  defp next_reference(state) do
    reference = Integer.to_string(state.next_reference)
    {reference, %{state | next_reference: state.next_reference + 1}}
  end

  defp schedule_heartbeat(seconds), do: Process.send_after(self(), :heartbeat, seconds * 1_000)

  defp replay_pending(pending) do
    Enum.each(pending, fn {reference, event} ->
      send(self(), {:replay_attempt_event, reference, event})
    end)
  end

  defp replay_pending_offers(pending) do
    Enum.each(pending, fn {reference, %{acceptance: acceptance}} ->
      send(self(), {:replay_job_accept, reference, acceptance})
    end)
  end

  defp acknowledge_pending(reference, %{"status" => "ok"}, state) do
    case Map.pop(state.pending_events, reference) do
      {nil, pending} ->
        %{state | pending_events: pending}

      {event, pending} ->
        active =
          if event["status"] in ~w(succeeded failed cancelled) do
            List.delete(state.active_attempt_ids, event["attempt_id"])
          else
            state.active_attempt_ids
          end

        %{state | pending_events: pending, active_attempt_ids: active}
    end
  end

  defp acknowledge_pending(_reference, _reply, state), do: state

  defp acknowledge_offer(reference, reply, state) do
    case Map.pop(state.pending_offers, reference) do
      {nil, pending} ->
        %{state | pending_offers: pending}

      {%{offer: offer}, pending} ->
        if reply["status"] == "ok" do
          notify(state, {:runner_message, "job_offer", offer})
          %{state | pending_offers: pending}
        else
          notify(state, {:runner_error, {:job_offer_rejected, offer["attempt_id"]}})

          %{
            state
            | pending_offers: pending,
              active_attempt_ids: List.delete(state.active_attempt_ids, offer["attempt_id"])
          }
        end
    end
  end

  defp notify_cancellations(
         %{
           "status" => "ok",
           "response" => %{"cancellation_requested_attempt_ids" => attempt_ids}
         },
         state
       )
       when is_list(attempt_ids) do
    Enum.each(attempt_ids, fn
      attempt_id when is_binary(attempt_id) ->
        notify(state, {:runner_message, "cancel", %{"attempt_id" => attempt_id}})

      _invalid_attempt_id ->
        :ok
    end)
  end

  defp notify_cancellations(_reply, _state), do: :ok

  defp notify(%{owner: owner}, message) when is_pid(owner), do: send(owner, message)
  defp notify(_state, _message), do: :ok

  defp default_capabilities do
    %{
      "os" => :os.type() |> elem(0) |> Atom.to_string(),
      "architecture" => :erlang.system_info(:system_architecture) |> to_string(),
      "docker" => true,
      "concurrency" => 1
    }
  end
end
