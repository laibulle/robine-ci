defmodule Robine.Adapters.Background.RunnerControl do
  @moduledoc "Keeps a local attempt lease alive and caches durable cancellation requests."

  use GenServer

  alias Robine.Pipelines

  @type server :: GenServer.server()

  @spec start(String.t(), Robine.ExecutionContext.t()) :: GenServer.on_start()
  def start(idempotency_token, context) when is_binary(idempotency_token) do
    GenServer.start(__MODULE__, {idempotency_token, context})
  end

  @spec cancellation_requested?(server()) :: boolean()
  def cancellation_requested?(server), do: GenServer.call(server, :cancellation_requested?)

  @spec stop(server()) :: :ok
  def stop(server) do
    if Process.alive?(server), do: GenServer.stop(server, :normal), else: :ok
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({idempotency_token, context}) do
    config = Application.fetch_env!(:robine, :runner_control)

    state = %{
      idempotency_token: idempotency_token,
      context: context,
      lease_seconds: Keyword.fetch!(config, :lease_seconds),
      heartbeat_interval_ms: Keyword.fetch!(config, :heartbeat_interval_ms),
      cancellation_poll_interval_ms: Keyword.fetch!(config, :cancellation_poll_interval_ms),
      cancellation_requested?: false
    }

    with :ok <- validate_intervals(state),
         :ok <- renew_lease(state) do
      schedule(:heartbeat, state.heartbeat_interval_ms)
      send(self(), :poll_cancellation)
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:initial_heartbeat_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:cancellation_requested?, _from, state) do
    {:reply, state.cancellation_requested?, state}
  end

  @impl GenServer
  def handle_info(:heartbeat, state) do
    _ = renew_lease(state)
    schedule(:heartbeat, state.heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(:poll_cancellation, %{cancellation_requested?: true} = state),
    do: {:noreply, state}

  def handle_info(:poll_cancellation, state) do
    cancellation_requested? = fetch_cancellation_request(state)
    schedule(:poll_cancellation, state.cancellation_poll_interval_ms)
    {:noreply, %{state | cancellation_requested?: cancellation_requested?}}
  end

  defp renew_lease(state) do
    case Pipelines.heartbeat_attempt(
           %{
             idempotency_token: state.idempotency_token,
             lease_seconds: state.lease_seconds
           },
           state.context
         ) do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_cancellation_request(state) do
    case Pipelines.cancellation_requested(
           %{idempotency_token: state.idempotency_token},
           state.context
         ) do
      {:ok, requested?} -> requested?
      {:error, _reason} -> false
    end
  end

  defp schedule(message, interval), do: Process.send_after(self(), message, interval)

  defp validate_intervals(state) do
    if state.heartbeat_interval_ms < state.lease_seconds * 1_000,
      do: :ok,
      else: {:error, :heartbeat_interval_must_be_shorter_than_lease}
  end
end
