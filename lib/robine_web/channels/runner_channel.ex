defmodule RobineWeb.RunnerChannel do
  use RobineWeb, :channel

  alias Robine.Runners
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  @impl true
  def join("runner:v1", hello, socket) do
    input = %{
      supported_protocol_versions: hello["supported_protocol_versions"],
      capabilities: hello["capabilities"],
      software_version: hello["software_version"]
    }

    case negotiate_and_reconcile(input, hello, socket) do
      {:ok, welcome} ->
        :ok = Phoenix.PubSub.subscribe(Robine.PubSub, "runner:#{socket.assigns.runner_id}")
        send(self(), {:resume_offers, Enum.map(welcome.resume, & &1.attempt_id)})
        {:ok, json_times(welcome), assign(socket, :protocol_version, welcome.protocol_version)}

      {:error, :incompatible_protocol} ->
        {:error, %{code: "incompatible_protocol", supported_protocol_versions: [1]}}

      {:error, reason} ->
        {:error, %{code: to_string(reason)}}
    end
  end

  @impl true
  def handle_in("job_accept", payload, socket) do
    input = %{
      idempotency_token: payload["idempotency_token"],
      message_id: payload["message_id"],
      sequence: 1,
      status: :preparing,
      reason: nil
    }

    with true <- is_binary(payload["attempt_id"]),
         true <- is_binary(input.idempotency_token),
         true <- is_binary(input.message_id),
         {:ok, attempt} <- Pipelines.record_runner_event(input, context(socket)),
         true <- attempt.id == payload["attempt_id"] do
      {:reply,
       {:ok,
        %{
          message_id: input.message_id,
          attempt_id: attempt.id,
          acknowledged_sequence: attempt.last_sequence
        }}, socket}
    else
      _invalid -> {:reply, {:error, %{code: "invalid_job_accept"}}, socket}
    end
  end

  def handle_in("job_reject", payload, socket) do
    input = %{
      idempotency_token: payload["idempotency_token"],
      message_id: payload["message_id"],
      sequence: 1,
      status: :failed,
      reason: :system_failure
    }

    with true <- is_binary(payload["attempt_id"]),
         true <- is_binary(input.idempotency_token),
         true <- is_binary(input.message_id),
         {:ok, attempt} <- Pipelines.record_runner_event(input, context(socket)),
         true <- attempt.id == payload["attempt_id"] do
      {:reply,
       {:ok,
        %{
          message_id: input.message_id,
          attempt_id: attempt.id,
          acknowledged_sequence: attempt.last_sequence
        }}, socket}
    else
      _invalid -> {:reply, {:error, %{code: "invalid_job_reject"}}, socket}
    end
  end

  @impl true
  def handle_in("attempt_event", payload, socket) do
    with {:ok, input} <- attempt_event_input(payload),
         {:ok, attempt} <- Pipelines.record_runner_event(input, context(socket)) do
      {:reply,
       {:ok,
        %{
          message_id: input.message_id,
          attempt_id: attempt.id,
          acknowledged_sequence: attempt.last_sequence
        }}, socket}
    else
      {:error, {:event_gap, expected, received}} ->
        {:reply,
         {:error, %{code: "event_gap", expected_sequence: expected, received_sequence: received}},
         socket}

      {:error, :message_id_conflict} ->
        {:reply, {:error, %{code: "message_id_conflict"}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{code: "invalid_attempt_event"}}, socket}
    end
  end

  def handle_in("log_event", payload, socket) do
    with {:ok, input} <- log_event_input(payload),
         :ok <- Pipelines.append_log_event(input, context(socket)) do
      {:reply, {:ok, %{sequence: input.sequence}}, socket}
    else
      {:error, _reason} -> {:reply, {:error, %{code: "invalid_log_event"}}, socket}
    end
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    with {:ok, acknowledgement} <-
           Runners.heartbeat(
             %{protocol_version: socket.assigns.protocol_version},
             context(socket)
           ),
         {:ok, leases} <- Pipelines.heartbeat_runner_attempts(%{}, context(socket)) do
      {:reply, {:ok, acknowledgement |> Map.merge(leases) |> json_times()}, socket}
    else
      {:error, _reason} -> {:stop, :normal, {:error, %{code: "unauthorized"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{code: "unsupported_message"}}, socket}

  @impl true
  def handle_info({:job_offer, offer}, socket) do
    push(socket, "job_offer", offer)
    {:noreply, socket}
  end

  def handle_info({:runner_revoked, runner_id}, %{assigns: %{runner_id: runner_id}} = socket) do
    push(socket, "runner_revoked", %{"cancel_active_attempts" => true})
    {:noreply, socket}
  end

  def handle_info({:resume_offers, attempt_ids}, socket) do
    Enum.each(attempt_ids, fn attempt_id ->
      case remote_job_offer(attempt_id, socket) do
        {:ok, offer} -> push(socket, "job_offer", offer)
        {:error, _reason} -> :ok
      end
    end)

    {:noreply, socket}
  end

  defp remote_job_offer(attempt_id, socket) do
    with {:ok, raw} <-
           Pipelines.remote_job_execution(%{attempt_id: attempt_id}, context(socket)) do
      public_url = Application.fetch_env!(:robine, :public_url) |> String.trim_trailing("/")
      transfer_base = "#{public_url}/api/v1/runners/attempts/#{attempt_id}"

      {:ok,
       %{
         "attempt_id" => attempt_id,
         "idempotency_token" => raw["idempotency_token"],
         "execution" => raw,
         "source_url" => if(checkout_required?(raw), do: transfer_base <> "/source"),
         "secrets_url" => transfer_base <> "/secrets",
         "builtins_url" => transfer_base
       }}
    end
  end

  defp checkout_required?(%{"steps" => steps}) when is_list(steps) do
    Enum.any?(steps, fn
      %{"kind" => kind, "value" => "checkout"} when kind in ["builtin", :builtin] -> true
      _step -> false
    end)
  end

  defp checkout_required?(_raw), do: false

  defp context(socket) do
    Dependencies.context(
      %{id: socket.assigns.runner_id, role: :runner},
      socket.assigns.correlation_id
    )
  end

  defp negotiate_and_reconcile(input, hello, socket) do
    with {:ok, welcome} <- Runners.negotiate_protocol(input, context(socket)),
         {:ok, reconciliation} <-
           Pipelines.reconcile_runner_attempts(
             %{active_attempt_ids: hello["active_attempt_ids"] || []},
             context(socket)
           ) do
      {:ok, Map.merge(welcome, reconciliation)}
    end
  end

  defp attempt_event_input(payload) do
    with {:ok, status} <- status(payload["status"]),
         {:ok, reason} <- reason(payload["reason"]) do
      {:ok,
       %{
         idempotency_token: payload["idempotency_token"],
         message_id: payload["message_id"],
         sequence: payload["sequence"],
         status: status,
         reason: reason
       }}
    end
  end

  defp status("preparing"), do: {:ok, :preparing}
  defp status("running"), do: {:ok, :running}
  defp status("cancelling"), do: {:ok, :cancelling}
  defp status("succeeded"), do: {:ok, :succeeded}
  defp status("failed"), do: {:ok, :failed}
  defp status("cancelled"), do: {:ok, :cancelled}
  defp status(_status), do: {:error, :invalid_status}

  defp reason(nil), do: {:ok, nil}
  defp reason("command_failed"), do: {:ok, :command_failed}
  defp reason("timeout"), do: {:ok, :timeout}
  defp reason("runner_lost"), do: {:ok, :runner_lost}
  defp reason("service_unavailable"), do: {:ok, :service_unavailable}
  defp reason("system_failure"), do: {:ok, :system_failure}
  defp reason("cancelled"), do: {:ok, :cancelled}
  defp reason(_reason), do: {:error, :invalid_reason}

  defp log_event_input(payload) do
    with {:ok, status} <- log_status(payload["status"]),
         {:ok, phase} <- log_phase(payload["phase"]),
         {:ok, stream} <- log_stream(payload["stream"]),
         {:ok, condition} <- log_condition(payload["condition"]) do
      {:ok,
       %{
         attempt_id: payload["attempt_id"],
         sequence: payload["sequence"],
         step_position: payload["step_position"],
         step_name: payload["step_name"],
         status: status,
         condition: condition,
         phase: phase,
         stream: stream,
         exit_code: payload["exit_code"],
         duration_ms: payload["duration_ms"],
         content: payload["content"]
       }}
    end
  end

  defp log_status(status) when status in ~w(running succeeded failed cancelled timed_out skipped),
    do: {:ok, String.to_existing_atom(status)}

  defp log_status(_status), do: {:error, :invalid_status}

  defp log_condition(condition) when condition in ~w(success failure always),
    do: {:ok, String.to_existing_atom(condition)}

  defp log_condition(nil), do: {:ok, nil}
  defp log_condition(_condition), do: {:error, :invalid_condition}

  defp log_phase(phase) when phase in ~w(image_acquisition service_preparation execution cleanup),
    do: {:ok, String.to_existing_atom(phase)}

  defp log_phase(nil), do: {:ok, :execution}
  defp log_phase(_phase), do: {:error, :invalid_phase}

  defp log_stream(stream) when stream in ~w(stdout stderr system combined),
    do: {:ok, String.to_existing_atom(stream)}

  defp log_stream(nil), do: {:ok, :combined}
  defp log_stream(_stream), do: {:error, :invalid_stream}

  defp json_times(map) do
    Map.new(map, fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      entry -> entry
    end)
  end
end
