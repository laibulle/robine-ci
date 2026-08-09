defmodule Robine.Runners.UseCases.NegotiateProtocol do
  @moduledoc "Negotiates and durably records one authenticated runner session version."

  alias Robine.ExecutionContext
  alias Robine.Runners.Dependencies
  alias Robine.Runners.Domain.Protocol

  def call(input, %ExecutionContext{
        actor: %{id: runner_id, role: :runner},
        dependencies: %{runners: %Dependencies{} = deps}
      }) do
    with %{
           supported_protocol_versions: versions,
           capabilities: capabilities,
           software_version: software
         } <-
           input,
         {:ok, negotiated} <- Protocol.negotiate(versions, capabilities, software),
         now = deps.clock.now(),
         :ok <-
           deps.registry.record_session(
             runner_id,
             negotiated.version,
             negotiated.software_version,
             negotiated.capabilities,
             now
           ) do
      {:ok,
       %{
         protocol_version: negotiated.version,
         heartbeat_interval_seconds: 20,
         stale_after_seconds: 60,
         server_time: now
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :unauthorized}
end
