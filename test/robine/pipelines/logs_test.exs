defmodule Robine.Pipelines.LogsTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.LogChunk
  alias Robine.Pipelines
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  test "persists UTF-8-safe idempotent chunks and reads them by cursor" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "logs")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "CI",
                 commit_sha: String.duplicate("f", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)

    raw_output = "\e[31m" <> String.duplicate("é", 40_000) <> "\e[0m\nfinished\n"
    output = String.duplicate("é", 40_000) <> "\nfinished\n"

    steps = [
      %{name: "Test", status: :succeeded, exit_code: 0, duration_ms: 42, output: raw_output}
    ]

    assert :ok =
             Pipelines.append_execution_logs(
               %{idempotency_token: attempt.idempotency_token, steps: steps},
               context
             )

    assert :ok =
             Pipelines.append_execution_logs(
               %{idempotency_token: attempt.idempotency_token, steps: steps},
               context
             )

    assert Repo.aggregate(LogChunk, :count) == 2

    assert {:ok, first} = Pipelines.list_job_logs(%{job_id: attempt.job_id, limit: 1}, context)
    assert length(first.chunks) == 1
    assert first.has_more
    assert String.valid?(hd(first.chunks).content)

    assert {:ok, second} =
             Pipelines.list_job_logs(
               %{job_id: attempt.job_id, after: first.next_cursor, limit: 10},
               context
             )

    assert length(second.chunks) == 1
    refute second.has_more
    assert Enum.map_join(first.chunks ++ second.chunks, & &1.content) == output

    assert {:ok, %{attempt: %{id: attempt_id}, job: %{id: job_id}}} =
             Pipelines.job_detail(%{job_id: attempt.job_id}, context)

    assert attempt_id == attempt.id
    assert job_id == attempt.job_id
  end
end
