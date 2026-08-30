defmodule Robine.Adapters.Persistence.Postgres.IdentityRepository do
  @moduledoc false
  @behaviour Robine.Identities.Ports.Repository
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    ApiToken,
    LocalCredential,
    OIDCIdentity,
    Session,
    User
  }

  alias Robine.Identities.Domain.User, as: DomainUser
  alias Robine.Identities.Domain.ApiToken, as: DomainApiToken
  alias Robine.Repo

  @impl true
  def bootstrap_user(user_attributes, credential_attributes) do
    Repo.transaction(fn ->
      Repo.query!("LOCK TABLE users IN EXCLUSIVE MODE")

      if Repo.aggregate(User, :count) == 0 do
        with {:ok, user} <- User.changeset(%User{}, user_attributes) |> Repo.insert(),
             {:ok, _credential} <-
               LocalCredential.changeset(
                 %LocalCredential{},
                 Map.put(credential_attributes, :user_id, user.id)
               )
               |> Repo.insert() do
          domain_user(user)
        else
          {:error, changeset} -> Repo.rollback({:identity_persistence, changeset})
        end
      else
        Repo.rollback(:already_bootstrapped)
      end
    end)
  end

  @impl true
  def get_local_user(email) do
    query =
      from user in User,
        join: credential in LocalCredential,
        on: credential.user_id == user.id,
        where: user.email == ^email,
        select: {user, credential.password_hash}

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      {user, hash} ->
        {:ok, domain_user(user) |> Map.from_struct() |> Map.put(:password_hash, hash)}
    end
  end

  @impl true
  def create_session(attributes) do
    %Session{}
    |> Session.changeset(attributes)
    |> Repo.insert()
    |> normalize(:session_persistence)
  end

  @impl true
  def revoke_session(token_digest, revoked_at) do
    case Repo.one(from session in Session, where: session.token_digest == ^token_digest) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Ecto.Changeset.change(revoked_at: revoked_at)
        |> Repo.update()
        |> normalize(:session_persistence)
    end
  end

  @impl true
  def get_session(token_digest, now) do
    query =
      from session in Session,
        join: user in User,
        on: user.id == session.user_id,
        where:
          session.token_digest == ^token_digest and is_nil(session.revoked_at) and
            session.expires_at > ^now and user.disabled == false,
        select: user

    case Repo.one(query) do
      nil -> {:error, :not_found}
      user -> {:ok, %{id: user.id, email: user.email, role: user.role}}
    end
  end

  @impl true
  def get_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, domain_user(user)}
    end
  end

  @impl true
  def count_usable_administrators do
    Repo.aggregate(
      from(user in User, where: user.role == :administrator and user.disabled == false),
      :count
    )
  end

  @impl true
  def update_role(id, role) do
    case Repo.get(User, id) do
      nil ->
        {:error, :not_found}

      user ->
        user |> Ecto.Changeset.change(role: role) |> Repo.update() |> normalize(:user_persistence)
    end
  end

  @impl true
  def find_or_provision_oidc_user(identity, user_attributes) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        identity.issuer <> ":" <> identity.subject
      ])

      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "oidc-email:" <> identity.email
      ])

      case oidc_user(identity) do
        {:ok, user} ->
          user

        {:error, :not_found} ->
          case linkable_local_user(identity.email) do
            {:ok, user} ->
              link_oidc_user(user, identity, user_attributes.inserted_at)

            {:error, :not_found} ->
              if Repo.exists?(from user in User, where: user.email == ^identity.email) do
                Repo.rollback(:oidc_email_collision)
              else
                create_oidc_user(identity, user_attributes)
              end
          end
      end
    end)
  end

  @impl true
  def list_users do
    users = Repo.all(from user in User, order_by: [asc: user.email])
    {:ok, Enum.map(users, &domain_user/1)}
  end

  @impl true
  def create_api_token(attributes) do
    Repo.transaction(fn ->
      active_user? =
        Repo.exists?(
          from user in User,
            where:
              user.id == ^attributes.user_id and user.disabled == false and
                user.role == :administrator
        )

      if active_user? do
        %ApiToken{}
        |> ApiToken.changeset(attributes)
        |> Repo.insert()
        |> case do
          {:ok, _token} -> :ok
          {:error, changeset} -> Repo.rollback({:api_token_persistence, changeset})
        end
      else
        Repo.rollback(:user_not_found)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_api_tokens do
    tokens =
      Repo.all(
        from token in ApiToken,
          order_by: [desc: token.inserted_at]
      )

    {:ok, Enum.map(tokens, &domain_api_token/1)}
  end

  @impl true
  def revoke_api_token(token_id, revoked_at) do
    case Repo.get(ApiToken, token_id) do
      nil ->
        {:error, :not_found}

      %{revoked_at: %DateTime{}} ->
        :ok

      token ->
        token
        |> Ecto.Changeset.change(revoked_at: revoked_at)
        |> Repo.update()
        |> normalize(:api_token_persistence)
    end
  end

  @impl true
  def resolve_api_token(token_digest, now) do
    query =
      from token in ApiToken,
        join: user in User,
        on: user.id == token.user_id,
        where:
          token.token_digest == ^token_digest and is_nil(token.revoked_at) and
            token.expires_at > ^now and user.disabled == false and
            user.role == :administrator,
        select: {token, user}

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      {token, user} ->
        _ = token |> Ecto.Changeset.change(last_used_at: now) |> Repo.update()

        {:ok,
         %{
           id: user.id,
           role: :artifact_uploader,
           token_id: token.id,
           permissions: token.permissions
         }}
    end
  end

  defp oidc_user(identity) do
    query =
      from oidc in OIDCIdentity,
        join: user in User,
        on: user.id == oidc.user_id,
        where: oidc.issuer == ^identity.issuer and oidc.subject == ^identity.subject,
        select: user

    case Repo.one(query) do
      nil -> {:error, :not_found}
      user -> {:ok, domain_user(user)}
    end
  end

  defp linkable_local_user(email) do
    query =
      from user in User,
        as: :user,
        join: credential in LocalCredential,
        on: credential.user_id == user.id,
        where:
          user.email == ^email and user.disabled == false and
            not exists(from oidc in OIDCIdentity, where: oidc.user_id == parent_as(:user).id),
        select: user

    case Repo.one(query) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp link_oidc_user(user, identity, inserted_at) do
    case create_oidc_identity(user.id, identity, inserted_at) do
      {:ok, _identity} -> domain_user(user)
      {:error, changeset} -> Repo.rollback({:identity_persistence, changeset})
    end
  end

  defp create_oidc_user(identity, user_attributes) do
    attributes = Map.merge(user_attributes, %{email: identity.email, disabled: false})

    with {:ok, user} <- User.changeset(%User{}, attributes) |> Repo.insert(),
         {:ok, _oidc} <- create_oidc_identity(user.id, identity, user_attributes.inserted_at) do
      domain_user(user)
    else
      {:error, changeset} -> Repo.rollback({:identity_persistence, changeset})
    end
  end

  defp create_oidc_identity(user_id, identity, inserted_at) do
    OIDCIdentity.changeset(%OIDCIdentity{}, %{
      user_id: user_id,
      issuer: identity.issuer,
      subject: identity.subject,
      inserted_at: inserted_at
    })
    |> Repo.insert()
  end

  defp normalize({:ok, _schema}, _tag), do: :ok
  defp normalize({:error, changeset}, tag), do: {:error, {tag, changeset}}

  defp domain_user(user) do
    %DomainUser{
      id: user.id,
      email: user.email,
      role: user.role,
      disabled: user.disabled,
      inserted_at: user.inserted_at
    }
  end

  defp domain_api_token(token) do
    %DomainApiToken{
      id: token.id,
      user_id: token.user_id,
      name: token.name,
      token_prefix: token.token_prefix,
      permissions: token.permissions,
      expires_at: token.expires_at,
      last_used_at: token.last_used_at,
      revoked_at: token.revoked_at,
      inserted_at: token.inserted_at
    }
  end
end
