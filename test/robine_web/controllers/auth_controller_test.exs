defmodule RobineWeb.AuthControllerTest do
  use RobineWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Robine.Adapters.Persistence.Postgres.Schemas.{OIDCIdentity, Session, User}
  alias Robine.Repo

  defmodule ProviderOutageOIDC do
    @behaviour Robine.Identities.Ports.OIDC

    @impl true
    def authorize_url(_config), do: {:error, :provider_unavailable}

    @impl true
    def callback(_config, _params), do: {:error, :provider_unavailable}
  end

  test "renders sign-in and first-run setup", %{conn: conn} do
    assert conn |> get(~p"/sign-in") |> html_response(200) =~ "Sign in"

    assert conn |> recycle() |> get(~p"/setup") |> html_response(200) =~
             "Create the administrator"
  end

  test "prefills setup from environment-specific form defaults", %{conn: conn} do
    previous = Application.get_env(:robine, :dev_setup_form_defaults)

    Application.put_env(:robine, :dev_setup_form_defaults, %{
      "token" => "local-token",
      "email" => "admin@local.test",
      "password" => "local-password"
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:robine, :dev_setup_form_defaults),
        else: Application.put_env(:robine, :dev_setup_form_defaults, previous)
    end)

    document = conn |> get(~p"/setup") |> html_response(200) |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#setup-form input[name='token']"),
             "value"
           ) ==
             ["local-token"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#setup-form input[name='email']"),
             "value"
           ) ==
             ["admin@local.test"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#setup-form input[name='password']"),
             "value"
           ) == ["local-password"]
  end

  test "bootstraps, signs in with a renewed session, and signs out", %{conn: conn} do
    conn =
      post(conn, ~p"/setup", %{
        "token" => "test-bootstrap-token",
        "email" => "admin@example.com",
        "password" => "a secure password"
      })

    assert redirected_to(conn) == ~p"/pipelines"
    assert token = get_session(conn, :session_token)
    assert Repo.aggregate(Session, :count) == 1

    home = conn |> recycle() |> get(~p"/") |> html_response(200) |> LazyHTML.from_fragment()
    assert home |> LazyHTML.query("a[href='/pipelines']") |> Enum.any?()

    conn = delete(recycle(conn), ~p"/sign-out")
    assert redirected_to(conn) == ~p"/sign-in"
    assert get_session(conn, :session_token) == nil

    [session] = Repo.all(Session)
    assert %DateTime{} = session.revoked_at
    assert :crypto.hash(:sha256, token) == session.token_digest
  end

  test "uses a generic error for invalid credentials", %{conn: conn} do
    conn = post(conn, ~p"/sign-in", %{"email" => "missing@example.com", "password" => "wrong"})
    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
  end

  test "provider outage creates no partial identity and preserves local administrator recovery",
       %{
         conn: conn
       } do
    previous_adapter = Application.fetch_env!(:robine, :oidc_adapter)
    previous_config = Application.fetch_env!(:robine, :oidc_config)

    Application.put_env(:robine, :oidc_adapter, ProviderOutageOIDC)

    Application.put_env(:robine, :oidc_config,
      base_url: "https://unavailable-id.example",
      client_id: "client",
      redirect_uri: "http://localhost/auth/oidc/callback"
    )

    on_exit(fn ->
      Application.put_env(:robine, :oidc_adapter, previous_adapter)
      Application.put_env(:robine, :oidc_config, previous_config)
    end)

    conn =
      post(conn, ~p"/setup", %{
        "token" => "test-bootstrap-token",
        "email" => "admin@example.com",
        "password" => "a secure password"
      })

    conn = conn |> recycle() |> delete(~p"/sign-out")
    baseline_sessions = Repo.aggregate(Session, :count)

    oidc_conn = conn |> recycle() |> get(~p"/auth/oidc")
    assert redirected_to(oidc_conn) == ~p"/sign-in"

    assert Phoenix.Flash.get(oidc_conn.assigns.flash, :error) ==
             "OpenID Connect is currently unavailable. Use local recovery sign-in."

    callback_conn =
      conn
      |> recycle()
      |> init_test_session(%{oidc_session_params: %{state: "state", nonce: "nonce"}})
      |> get(~p"/auth/oidc/callback", %{"code" => "unreachable"})

    assert redirected_to(callback_conn) == ~p"/sign-in"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :error) ==
             "SSO sign-in could not be verified. Please try again or use local recovery sign-in."

    assert get_session(callback_conn, :oidc_session_params) == nil
    assert Repo.aggregate(User, :count) == 1
    assert Repo.aggregate(OIDCIdentity, :count) == 0
    assert Repo.aggregate(Session, :count) == baseline_sessions

    recovery_conn =
      conn
      |> recycle()
      |> post(~p"/sign-in", %{
        "email" => "admin@example.com",
        "password" => "a secure password"
      })

    assert redirected_to(recovery_conn) == ~p"/pipelines"
    assert get_session(recovery_conn, :session_token)
    assert Repo.aggregate(Session, :count) == baseline_sessions + 1
    assert {:ok, _view, html} = live(recovery_conn, ~p"/admin")
    assert html =~ "Administration"
  end
end
