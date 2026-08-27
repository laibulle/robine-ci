defmodule Robine.TestSupport.DeploymentExecutorAdapter do
  @moduledoc false

  def request(:get, "https://ci.example.test/artifact", _headers, nil, config),
    do: {:ok, 200, Map.fetch!(config, :artifact_body)}

  def request(:get, "https://ci.example.test/secrets", _headers, nil, _config),
    do: {:ok, 200, Jason.encode!(%{"secrets" => %{}})}

  def send_deployment_event(_client, event, config) do
    Agent.update(Map.fetch!(config, :event_agent), &[event | &1])
  end

  def docker(arguments, config) do
    Agent.update(Map.fetch!(config, :docker_agent), &[arguments | &1])

    if "inspect" in arguments,
      do: {:error, :not_found},
      else: {:ok, "ok"}
  end
end
