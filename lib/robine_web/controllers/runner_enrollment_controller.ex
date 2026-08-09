defmodule RobineWeb.RunnerEnrollmentController do
  use RobineWeb, :controller

  alias Robine.Runners
  alias Robine.Runtime.Dependencies
  alias RobineWeb.LoginRateLimiter

  def create(conn, params) do
    rate_key = {:runner_enrollment, conn.remote_ip}

    if LoginRateLimiter.allowed?(rate_key) do
      context =
        Dependencies.context(
          %{id: "anonymous:runner-enrollment", role: :runner},
          Ecto.UUID.generate()
        )

      case Runners.enroll(%{token: params["token"], name: params["name"]}, context) do
        {:ok, enrollment} ->
          conn
          |> put_status(:created)
          |> json(%{runner_id: enrollment.runner_id, credential: enrollment.credential})

        {:error, :invalid_enrollment_request} ->
          conn |> put_status(:bad_request) |> json(%{error: "invalid enrollment request"})

        {:error, :invalid_runner} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid runner name"})

        {:error, _reason} ->
          conn |> put_status(:unauthorized) |> json(%{error: "invalid enrollment token"})
      end
    else
      conn
      |> put_resp_header("retry-after", "60")
      |> put_status(:too_many_requests)
      |> json(%{error: "too many enrollment attempts"})
    end
  end
end
