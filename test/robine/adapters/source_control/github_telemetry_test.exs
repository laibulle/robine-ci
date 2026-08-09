defmodule Robine.Adapters.SourceControl.GitHubTelemetryTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.SourceControl.GitHubTelemetry

  test "emits bounded API and rate-limit dimensions without response content" do
    handler = "github-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:robine, :github, :api, :request],
        fn event, measurements, metadata, _config ->
          send(parent, {:github_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    response = %Req.Response{
      status: 403,
      body: %{"message" => "fixture-sensitive-body"},
      headers: %{
        "x-ratelimit-remaining" => ["0"],
        "x-ratelimit-limit" => ["5000"],
        "x-ratelimit-reset" => ["1"]
      }
    }

    assert :ok = GitHubTelemetry.emit(:get, System.monotonic_time(), {:ok, response})

    assert_receive {:github_telemetry, [:robine, :github, :api, :request], measurements, metadata}

    assert measurements.rate_limit_remaining == 0
    assert measurements.rate_limit_limit == 5000
    assert metadata == %{method: :get, outcome: :http_error, status: 403}
    refute inspect({measurements, metadata}) =~ "fixture-sensitive-body"

    assert %{
             outcome: :http_error,
             status: 403,
             rate_limit_remaining: 0,
             rate_limit_limit: 5000
           } = Robine.Adapters.SourceControl.GitHubApiMonitor.snapshot()
  end
end
