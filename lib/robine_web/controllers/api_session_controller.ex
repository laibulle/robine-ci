defmodule RobineWeb.ApiSessionController do
  use RobineWeb, :controller

  alias Robine.Identities
  alias Robine.Runtime.Dependencies
  alias RobineWeb.LoginRateLimiter

  def create(conn, %{"email" => email, "password" => password}) do
    if LoginRateLimiter.allowed?({conn.remote_ip, :api_login}) do
      case Identities.authenticate_local(%{email: email, password: password}, context(conn)) do
        {:ok, session} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> json(%{
            token: session.token,
            token_type: "Bearer",
            expires_at: DateTime.to_iso8601(session.expires_at),
            user: session.user
          })

        {:error, _reason} ->
          unauthorized(conn)
      end
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:too_many_requests)
      |> json(%{error: "too_many_requests"})
    end
  end

  def create(conn, _params), do: unauthorized(conn)

  defp unauthorized(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:unauthorized)
    |> json(%{error: "invalid_credentials"})
  end

  defp context(conn) do
    Dependencies.context(
      %{id: "api:anonymous", role: :viewer},
      conn.assigns[:request_id] || "api-session"
    )
  end
end
