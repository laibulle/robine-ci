defmodule Robine.Adapters.Deployments.HttpVerifierTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Deployments.HttpVerifier

  test "checks bounded health and the exact same-origin release version" do
    request = fn options ->
      case Keyword.fetch!(options, :url) do
        "https://ci.example.test/health/ready" ->
          {:ok, %{status: 200, body: "ready"}}

        "https://ci.example.test/health/version" ->
          {:ok, %{status: 200, body: %{"version" => "v0.2.0"}}}
      end
    end

    assert {:ok, %{status: 200, release: "v0.2.0"}} =
             HttpVerifier.verify(
               %{
                 url: "https://ci.example.test/health/ready",
                 expected_status: %{first: 200, last: 299},
                 version_path: "/health/version"
               },
               "v0.2.0",
               request: request
             )
  end

  test "fails closed on redirects and version mismatch" do
    redirect = fn _options -> {:ok, %{status: 302, body: ""}} end

    assert {:error, :unexpected_health_status} =
             HttpVerifier.verify(
               %{
                 url: "https://ci.example.test/health",
                 expected_status: %{first: 200, last: 299}
               },
               "v0.2.0",
               request: redirect
             )

    request = fn options ->
      if String.ends_with?(Keyword.fetch!(options, :url), "/version"),
        do: {:ok, %{status: 200, body: %{"version" => "v0.1.0"}}},
        else: {:ok, %{status: 200, body: "ready"}}
    end

    assert {:error, :deployed_version_mismatch} =
             HttpVerifier.verify(
               %{
                 url: "https://ci.example.test/health",
                 expected_status: %{first: 200, last: 299},
                 version_path: "/version"
               },
               "v0.2.0",
               request: request
             )
  end
end
