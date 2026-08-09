defmodule RobineWeb.AuthController do
  use RobineWeb, :controller

  alias Robine.Identities
  alias Robine.Runtime.Dependencies
  alias RobineWeb.LoginRateLimiter

  def new(conn, _params), do: render(conn, :new, oidc_enabled: oidc_enabled?())
  def bootstrap(conn, _params), do: render(conn, :bootstrap)

  def create(conn, %{"email" => email, "password" => password}) do
    if LoginRateLimiter.allowed?({conn.remote_ip, :local_login}) do
      case Identities.authenticate_local(%{email: email, password: password}, context(conn)) do
        {:ok, session} ->
          identity_event(:login, %{method: :local, outcome: :success})
          signed_in(conn, session)

        {:error, _reason} ->
          identity_event(:login, %{method: :local, outcome: :failure})
          conn |> put_flash(:error, "Invalid email or password.") |> redirect(to: ~p"/sign-in")
      end
    else
      identity_event(:rate_limit, %{method: :local})

      conn
      |> put_status(:too_many_requests)
      |> put_flash(:error, "Too many attempts. Try again in one minute.")
      |> render(:new, oidc_enabled: oidc_enabled?())
    end
  end

  def create(conn, _params),
    do:
      conn
      |> put_flash(:error, "Email and password are required.")
      |> render(:new, oidc_enabled: oidc_enabled?())

  def oidc(conn, _params) do
    if LoginRateLimiter.allowed?({conn.remote_ip, :oidc_login}) do
      case Identities.start_oidc(%{}, context(conn)) do
        {:ok, authorization} ->
          conn
          |> put_session(:oidc_session_params, authorization.session_params)
          |> redirect(external: authorization.url)

        {:error, _reason} ->
          identity_event(:oidc_failure, %{phase: :authorization})

          conn
          |> put_flash(
            :error,
            "OpenID Connect is currently unavailable. Use local recovery sign-in."
          )
          |> redirect(to: ~p"/sign-in")
      end
    else
      identity_event(:rate_limit, %{method: :oidc})

      conn
      |> put_status(:too_many_requests)
      |> put_flash(:error, "Too many attempts. Try again in one minute.")
      |> render(:new, oidc_enabled: oidc_enabled?())
    end
  end

  def oidc_callback(conn, params) do
    session_params = get_session(conn, :oidc_session_params)

    result =
      if is_map(session_params),
        do:
          Identities.complete_oidc(
            %{params: params, session_params: session_params},
            context(conn)
          ),
        else: {:error, :missing_oidc_session}

    conn = delete_session(conn, :oidc_session_params)

    case result do
      {:ok, session} ->
        identity_event(:login, %{method: :oidc, outcome: :success})
        signed_in(conn, session)

      {:error, _reason} ->
        identity_event(:login, %{method: :oidc, outcome: :failure})
        identity_event(:oidc_failure, %{phase: :callback})

        conn
        |> put_flash(
          :error,
          "SSO sign-in could not be verified. Please try again or use local recovery sign-in."
        )
        |> redirect(to: ~p"/sign-in")
    end
  end

  def create_bootstrap(conn, %{"token" => token, "email" => email, "password" => password}) do
    case Identities.bootstrap_administrator(
           %{token: token, email: email, password: password},
           context(conn)
         ) do
      {:ok, _user} -> create(conn, %{"email" => email, "password" => password})
      {:error, reason} -> conn |> put_flash(:error, bootstrap_error(reason)) |> render(:bootstrap)
    end
  end

  def create_bootstrap(conn, _params),
    do: conn |> put_flash(:error, "All fields are required.") |> render(:bootstrap)

  def delete(conn, _params) do
    if token = get_session(conn, :session_token) do
      result = Identities.revoke_session(%{token: token}, context(conn))

      identity_event(:session_revocation, %{
        outcome: if(result == :ok, do: :success, else: :failure)
      })
    end

    conn |> clear_session() |> configure_session(drop: true) |> redirect(to: ~p"/sign-in")
  end

  defp signed_in(conn, session) do
    conn
    |> put_session(:session_token, session.token)
    |> configure_session(renew: true)
    |> redirect(to: ~p"/")
  end

  defp context(conn),
    do:
      Dependencies.context(
        %{id: "web:anonymous", role: :viewer},
        conn.assigns[:request_id] || "web"
      )

  defp bootstrap_error(:already_bootstrapped), do: "This instance has already been initialized."

  defp bootstrap_error(:bootstrap_token_expired),
    do: "The setup token expired. Restart with a new token."

  defp bootstrap_error(:weak_password), do: "Use at least 12 characters."
  defp bootstrap_error(_reason), do: "Setup could not be completed. Check the token and fields."
  defp oidc_enabled?, do: not is_nil(Application.get_env(:robine, :oidc_config))

  defp identity_event(event, metadata) do
    :telemetry.execute([:robine, :identity, event], %{count: 1}, metadata)
  end
end
