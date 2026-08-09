defmodule Robine.TestSupport.DockerEndpoint do
  @moduledoc false

  @loopback "127.0.0.1"

  def host do
    case System.get_env("DOCKER_HOST") do
      value when is_binary(value) -> URI.parse(value).host || @loopback
      nil -> @loopback
    end
  end

  def publish_address do
    if host() == @loopback, do: @loopback, else: "0.0.0.0"
  end

  def http_url(port), do: "http://#{host()}:#{port}"
end
