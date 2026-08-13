defmodule Robine.BackendTenantIsolationTest do
  use Robine.DataCase, async: false

  alias Robine.Backend
  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  test "backend calls cannot observe another tenant's pipelines" do
    role = "robine_rls_test_#{System.unique_integer([:positive])}"
    quoted_role = ~s("#{role}")

    Repo.query!("CREATE ROLE #{quoted_role} NOSUPERUSER NOBYPASSRLS", [])
    Repo.query!("GRANT USAGE ON SCHEMA public TO #{quoted_role}", [])

    Repo.query!(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{quoted_role}",
      []
    )

    Repo.query!("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{quoted_role}", [])

    pipeline_a = insert_pipeline("workspace-a")
    pipeline_b = insert_pipeline("workspace-b")

    Repo.query!("SET LOCAL ROLE #{quoted_role}", [])

    assert {:ok, rows_a} = Backend.call(context("workspace-a"), Pipelines, :list_pipelines, [%{}])
    assert Enum.map(rows_a, & &1.id) == [pipeline_a]

    assert {:ok, rows_b} = Backend.call(context("workspace-b"), Pipelines, :list_pipelines, [%{}])
    assert Enum.map(rows_b, & &1.id) == [pipeline_b]
  end

  defp insert_pipeline(tenant_id) do
    id = Ecto.UUID.generate()

    Repo.query!("SELECT set_config('robine.tenant_id', $1, true)", [tenant_id])

    Repo.query!(
      """
      INSERT INTO pipelines
        (id, repository_id, workflow_name, commit_sha, status, inserted_at)
      VALUES ($1, $2, $3, $4, $5, now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        tenant_id,
        String.duplicate("a", 40),
        "queued"
      ]
    )

    id
  end

  defp context(tenant_id) do
    {:ok, context} =
      Dependencies.embedded_context(
        %{id: "workspace-user", role: :member},
        tenant_id,
        [:ci_read],
        "request:#{tenant_id}"
      )

    context
  end
end
