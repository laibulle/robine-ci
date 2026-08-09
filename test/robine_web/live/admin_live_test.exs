defmodule RobineWeb.AdminLiveTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.{RunnerEnrollmentToken, Secret, User}
  alias Robine.{Repo, Runners}
  alias Robine.Runtime.Dependencies

  test "shows secret-free identity configuration and protects the last administrator", %{
    conn: conn
  } do
    conn = signed_in_conn(conn)
    admin = Repo.one!(User)

    assert {:ok, view, html} = live(conn, ~p"/admin")
    assert html =~ "Administration"
    assert html =~ "Optional SSO is disabled"
    assert html =~ "Instance health"
    assert html =~ "PostgreSQL"
    assert html =~ "Durable queue"
    assert html =~ "Blob storage"
    assert html =~ "GitLab"
    assert html =~ "Forgejo"
    assert html =~ "Retention policy"
    assert html =~ "Connect GitHub"
    assert html =~ "GitLab and Forgejo credentials"
    assert html =~ "Remote runner enrollment"
    assert has_element?(view, "#rotate-secret-keys", "Rotate keys")
    assert html =~ "30 days"
    assert html =~ "admin@example.com"
    refute html =~ "test-bootstrap-token"

    assert has_element?(view, "#github-setup-assistant")
    assert has_element?(view, "#github-setup-create")

    view |> element("#github-setup-step-2") |> render_click()
    assert has_element?(view, "#github-setup-permissions")
    assert has_element?(view, "#github-setup-permissions", "Metadata")
    assert has_element?(view, "#github-setup-permissions", "Pull request")

    view |> element("#github-setup-step-3") |> render_click()
    assert has_element?(view, "#github-setup-credentials")
    assert has_element?(view, "#github-private-key-form")
    assert has_element?(view, "#github-webhook-secret-form")

    html =
      view
      |> form("#role-#{admin.id}", %{"user_id" => admin.id, "role" => "viewer"})
      |> render_change()

    assert html =~ "Create another usable administrator"
    assert Repo.get!(User, admin.id).role == :administrator

    assert view |> element("#rotate-secret-keys") |> render_click() =~ "rotation complete"

    credential = "encrypted-webhook-fixture"

    rendered =
      view
      |> form("#github-webhook-secret-form", %{"value" => credential})
      |> render_submit()

    assert rendered =~ "Webhook secret encrypted and stored"
    refute rendered =~ credential
    stored = Repo.get_by!(Secret, name: "GITHUB_WEBHOOK_SECRET", scope: :instance)
    refute stored.ciphertext =~ credential

    view |> element("#verify-github-setup") |> render_click()
    assert has_element?(view, "#github-setup-verify")
    assert has_element?(view, "a[href='/repositories']", "Trust repositories in Robine")

    gitlab_token = "gitlab-encrypted-token"

    rendered =
      view
      |> form("#gitlab-token-form", %{"value" => gitlab_token})
      |> render_submit()

    assert rendered =~ "GitLab API token encrypted and stored"
    refute rendered =~ gitlab_token
    stored_gitlab = Repo.get_by!(Secret, name: "GITLAB_TOKEN", scope: :instance)
    refute stored_gitlab.ciphertext =~ gitlab_token

    enrollment_html =
      view
      |> element("#create-runner-enrollment")
      |> render_click()

    assert enrollment_html =~ "Copy this command now"
    assert enrollment_html =~ "ROBINE_RUNNER_ENROLLMENT_TOKEN="
    assert enrollment_html =~ "rbe_"
    assert enrollment_html =~ "--name"
    assert enrollment_html =~ "RUNNER_NAME"

    stored_enrollment = Repo.one!(RunnerEnrollmentToken)
    refute enrollment_html =~ Base.url_encode64(stored_enrollment.token_digest, padding: false)
  end

  test "redirects non-administrators from instance administration", %{conn: conn} do
    conn = signed_in_conn(conn)
    admin = Repo.one!(User)
    admin |> Ecto.Changeset.change(role: :maintainer) |> Repo.update!()

    assert {:error, {:redirect, %{to: "/pipelines"}}} = live(conn, ~p"/admin")
  end

  test "prefills the GitHub private key from development-only configuration", %{conn: conn} do
    previous = Application.get_env(:robine, :dev_github_private_key_form_default)
    Application.put_env(:robine, :dev_github_private_key_form_default, "development-private-key")

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:robine, :dev_github_private_key_form_default),
        else: Application.put_env(:robine, :dev_github_private_key_form_default, previous)
    end)

    assert {:ok, view, _html} = conn |> signed_in_conn() |> live(~p"/admin")
    view |> element("#github-setup-step-3") |> render_click()

    document = view |> render() |> LazyHTML.from_fragment()

    assert document
           |> LazyHTML.query("#github-private-key")
           |> LazyHTML.text() == "development-private-key"
  end

  test "administers an enrolled runner from the fleet view", %{conn: conn} do
    conn = signed_in_conn(conn)
    admin = Repo.one!(User)

    admin_context =
      Dependencies.context(%{id: admin.id, role: :administrator}, Ecto.UUID.generate())

    anonymous_context =
      Dependencies.context(%{id: "anonymous", role: :runner}, Ecto.UUID.generate())

    assert {:ok, enrollment} = Runners.create_enrollment_token(%{}, admin_context)

    assert {:ok, identity} =
             Runners.enroll(%{token: enrollment.token, name: "ui-runner"}, anonymous_context)

    runner_context =
      Dependencies.context(%{id: identity.runner_id, role: :runner}, Ecto.UUID.generate())

    assert {:ok, _welcome} =
             Runners.negotiate_protocol(
               %{
                 supported_protocol_versions: [1],
                 software_version: "0.2.0-dev",
                 capabilities: %{"docker" => true, "concurrency" => 1}
               },
               runner_context
             )

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#runner-form-#{identity.runner_id}")
    assert has_element?(view, "#runner-state-#{identity.runner_id}", "Drain")

    view
    |> form("#runner-form-#{identity.runner_id}", %{
      "runner" => %{
        "runner_id" => identity.runner_id,
        "name" => "ui-gpu",
        "labels" => "gpu, eu-west"
      }
    })
    |> render_submit()

    stored =
      Repo.get!(Robine.Adapters.Persistence.Postgres.Schemas.RemoteRunner, identity.runner_id)

    assert stored.name == "ui-gpu"
    assert stored.labels == ["gpu", "eu-west"]

    view |> element("#runner-state-#{identity.runner_id}") |> render_click()

    assert Repo.get!(
             Robine.Adapters.Persistence.Postgres.Schemas.RemoteRunner,
             identity.runner_id
           ).admin_state == :draining

    assert has_element?(view, "#runner-state-#{identity.runner_id}", "Enable")

    view |> element("#rotate-runner-#{identity.runner_id}") |> render_click()
    assert has_element?(view, "#runner-credential-result")

    view |> element("#revoke-runner-#{identity.runner_id}") |> render_click()

    assert Repo.get!(
             Robine.Adapters.Persistence.Postgres.Schemas.RemoteRunner,
             identity.runner_id
           ).admin_state == :revoked

    refute has_element?(view, "#runner-form-#{identity.runner_id}")
  end

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
