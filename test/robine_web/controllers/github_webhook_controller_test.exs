defmodule RobineWeb.GitHubWebhookControllerTest do
  use RobineWeb.ConnCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.ProcessGitHubDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.GitHubDelivery
  alias Robine.Repo

  test "accepts a valid signature and deduplicates the delivery", %{conn: conn} do
    body = Jason.encode!(%{"zen" => "precise hooks"})
    delivery_id = "delivery-#{System.unique_integer([:positive])}"
    signature = sign(body)

    conn = request(conn, body, delivery_id, signature)
    assert conn.status == 202
    assert json_response(conn, 202) == %{"status" => "accepted"}
    assert Repo.get!(GitHubDelivery, delivery_id).status == :pending
    assert_enqueued(worker: ProcessGitHubDeliveryWorker, args: %{delivery_id: delivery_id})

    duplicate = request(build_conn(), body, delivery_id, signature)
    assert duplicate.status == 200
    assert json_response(duplicate, 200) == %{"status" => "duplicate"}

    assert Repo.aggregate(
             from(job in Oban.Job, where: job.worker == ^inspect(ProcessGitHubDeliveryWorker)),
             :count
           ) == 1
  end

  test "rejects invalid signatures before persistence", %{conn: conn} do
    delivery_id = "invalid-#{System.unique_integer([:positive])}"
    conn = request(conn, "{}", delivery_id, "sha256=" <> String.duplicate("0", 64))
    assert conn.status == 401
    assert Repo.get(GitHubDelivery, delivery_id) == nil
  end

  defp request(conn, body, delivery_id, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-delivery", delivery_id)
    |> put_req_header("x-github-event", "push")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(~p"/api/github/webhooks", body)
  end

  defp sign(body) do
    secret = Application.fetch_env!(:robine, :github_webhook_secret)
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end
end
