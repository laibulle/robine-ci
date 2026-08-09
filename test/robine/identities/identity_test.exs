defmodule Robine.Identities.IdentityTest do
  use Robine.DataCase, async: false

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{Session, User}
  alias Robine.Identities
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  test "bootstraps exactly one administrator, authenticates, and revokes the session" do
    context = Dependencies.context(%{id: "setup", role: :administrator}, "bootstrap")

    request = %{
      token: "test-bootstrap-token",
      email: "Admin@Example.com",
      password: "a secure password"
    }

    assert {:ok, %{email: "admin@example.com", role: :administrator} = user} =
             Identities.bootstrap_administrator(request, context)

    assert {:error, :already_bootstrapped} = Identities.bootstrap_administrator(request, context)

    assert {:error, :invalid_credentials} =
             Identities.authenticate_local(
               %{email: user.email, password: "wrong password"},
               context
             )

    assert {:ok, %{token: token, user: %{id: user_id}}} =
             Identities.authenticate_local(
               %{email: "ADMIN@example.com", password: "a secure password"},
               context
             )

    assert user_id == user.id
    digest = :crypto.hash(:sha256, token)

    assert %Session{revoked_at: nil} =
             Repo.one!(from session in Session, where: session.token_digest == ^digest)

    assert :ok = Identities.revoke_session(%{token: token}, context)

    assert %Session{revoked_at: %DateTime{}} =
             Repo.one!(from session in Session, where: session.token_digest == ^digest)
  end

  test "rejects invalid and expired bootstrap tokens" do
    context = Dependencies.context(%{id: "setup", role: :administrator}, "bootstrap")
    request = %{token: "wrong", email: "admin@example.com", password: "a secure password"}

    assert {:error, :invalid_bootstrap_token} =
             Identities.bootstrap_administrator(request, context)

    identity_dependencies = %{
      context.dependencies.identities
      | bootstrap_expires_at: ~U[2020-01-01 00:00:00Z]
    }

    expired_context = %{
      context
      | dependencies: %{context.dependencies | identities: identity_dependencies}
    }

    assert {:error, :bootstrap_token_expired} =
             Identities.bootstrap_administrator(
               %{request | token: "test-bootstrap-token"},
               expired_context
             )
  end

  test "prevents demoting the last usable administrator" do
    context = Dependencies.context(%{id: "setup", role: :administrator}, "bootstrap")

    assert {:ok, user} =
             Identities.bootstrap_administrator(
               %{
                 token: "test-bootstrap-token",
                 email: "admin@example.com",
                 password: "a secure password"
               },
               context
             )

    assert {:error, :last_administrator} =
             Identities.change_user_role(%{user_id: user.id, role: :viewer}, context)

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      email: "second@example.com",
      role: :administrator,
      disabled: false
    })

    assert {:ok, %{role: :viewer}} =
             Identities.change_user_role(%{user_id: user.id, role: :viewer}, context)
  end
end
