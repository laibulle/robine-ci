defmodule RobineWeb.RepositoryDeploymentLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.DeploymentEnvironment
  alias Robine.{Repo, Repositories}
  alias Robine.Runtime.Dependencies

  test "administrator configures a pinned native environment without secret values", %{conn: conn} do
    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "deployment-live")

    assert {:ok, repository} =
             Repositories.register_github_repository(
               %{provider_id: 88_001, installation_id: 42, full_name: "private/deployable"},
               context
             )

    assert {:ok, repository_view, _html} = live(conn, ~p"/repositories/#{repository.id}")
    assert has_element?(repository_view, "#repository-deployments")

    assert {:ok, deployments, _html} =
             live(conn, ~p"/repositories/#{repository.id}/deployments")

    assert has_element?(deployments, "#deployment-environment-form")
    assert has_element?(deployments, "#environment-count", "0 environments")
    assert has_element?(deployments, "#deployment-environments-empty")

    deployments
    |> form("#deployment-environment-form", %{
      "environment" => %{
        "name" => "production",
        "protection" => "protected",
        "runner_labels" => "production, amd64",
        "deployment_root" => "/opt/robine",
        "network_name" => "robine-production",
        "migration_policy" => "forward_only",
        "verification_url" => "https://ci.example.test/health/ready",
        "version_path" => "/health/version",
        "application_name" => "server",
        "application_image" => "hexpm/elixir@sha256:#{String.duplicate("a", 64)}",
        "secret_key_reference" => "secret-key-base",
        "postgres_enabled" => "true",
        "postgres_image" => "postgres:18-alpine@sha256:#{String.duplicate("b", 64)}",
        "postgres_volume" => "postgres-data",
        "postgres_password_reference" => "postgres-password",
        "storage_enabled" => "false",
        "storage_image" => "",
        "storage_volume" => "object-storage-data",
        "storage_password_reference" => "object-storage-password",
        "ingress_enabled" => "false",
        "ingress_image" => ""
      }
    })
    |> render_submit()

    assert has_element?(deployments, "#environment-count", "1 environments")
    assert has_element?(deployments, "#deployment-environments article")
    assert has_element?(deployments, "#request-deployment-#{Repo.one!(DeploymentEnvironment).id}")

    stored = Repo.one!(DeploymentEnvironment)
    assert stored.protection == :protected
    assert stored.runner_labels == ["production", "amd64"]
    assert Enum.map(stored.services, & &1["role"]) == ["application", "postgres"]
    refute inspect(stored) =~ "a secure password"
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "deployment-admin@example.com",
      "password" => "a secure password"
    })
  end
end
