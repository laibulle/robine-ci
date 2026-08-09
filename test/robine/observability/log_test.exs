defmodule Robine.Observability.LogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Robine.Observability.Log

  test "emits allowlisted correlation metadata and drops secret-bearing values" do
    secret = "do-not-log-this-secret"
    long_delivery = String.duplicate("d", 200)

    output =
      capture_log(fn ->
        assert :ok =
                 Log.event(:warning, "runner.attempt.completed", %{
                   correlation_id: "attempt:123",
                   delivery_id: long_delivery,
                   pipeline_id: "pipeline-123",
                   job_id: "job-123",
                   attempt_id: "attempt-123",
                   outcome: :succeeded,
                   secret: secret,
                   payload: %{"token" => secret},
                   status: %{"unsafe" => secret}
                 })
      end)

    assert output =~ "runner.attempt.completed"
    assert output =~ "correlation_id=attempt:123"
    assert output =~ "pipeline_id=pipeline-123"
    assert output =~ "job_id=job-123"
    assert output =~ "attempt_id=attempt-123"
    assert output =~ "outcome=succeeded"
    assert output =~ "delivery_id=#{String.duplicate("d", 128)}"
    assert output =~ "status=invalid"
    refute output =~ secret
    refute output =~ "payload"
    refute output =~ "secret="
    refute output =~ String.duplicate("d", 129)
  end
end
