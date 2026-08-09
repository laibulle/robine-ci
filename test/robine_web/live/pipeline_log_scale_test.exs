defmodule RobineWeb.PipelineLogScaleTest do
  use RobineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.LogRepository
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  @chunk_bytes 62_500
  @chunk_count 1_600
  @retained_bytes @chunk_bytes * @chunk_count

  @tag timeout: 120_000
  test "navigates exactly 100 MB of retained logs through a bounded LiveView window", %{
    conn: conn
  } do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "100mb-navigation")

    assert @retained_bytes == 100_000_000

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Large log CI",
                 commit_sha: String.duplicate("9", 40),
                 jobs: %{"large-log" => %{needs: []}}
               },
               context
             )

    assert {:ok, _queued} = Pipelines.queue_pipeline(%{pipeline_id: pipeline.id}, context)
    assert {:ok, attempt} = Pipelines.claim_next_job(%{}, context)
    content = String.duplicate("x", @chunk_bytes)

    1..@chunk_count
    |> Enum.chunk_every(100)
    |> Enum.each(fn sequences ->
      rows =
        Enum.map(sequences, fn sequence ->
          %{
            attempt_id: attempt.id,
            sequence: sequence,
            phase: "execution",
            step_position: sequence,
            step_name: "Segment #{sequence}",
            step_status: "running",
            exit_code: nil,
            duration_ms: sequence,
            content: content
          }
        end)

      assert :ok = LogRepository.insert_all(rows)
    end)

    assert {:ok, snapshot} = Pipelines.pipeline_snapshot(%{pipeline_id: pipeline.id}, context)
    job = hd(snapshot.jobs)
    assert {:ok, view, html} = live(conn, ~p"/pipelines/#{pipeline.id}/jobs/#{job.id}")

    assert html =~ "Showing at most 50 recent 64 KB segments"
    assert html =~ ~s(id="log-1")
    assert html =~ ~s(id="log-50")
    refute html =~ ~s(id="log-51")
    assert byte_size(html) < 4_000_000

    assert {:memory, process_bytes} = Process.info(view.pid, :memory)
    assert process_bytes < 30_000_000
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
