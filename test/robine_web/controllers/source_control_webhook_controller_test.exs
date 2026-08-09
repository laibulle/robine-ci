defmodule RobineWeb.SourceControlWebhookControllerTest do
  use RobineWeb.ConnCase, async: false
  use Oban.Testing, repo: Robine.Repo

  import Ecto.Query

  alias Robine.Adapters.Background.ProcessGitHubDeliveryWorker
  alias Robine.Adapters.Persistence.Postgres.Schemas.GitHubDelivery
  alias Robine.Repo

  setup do
    previous_gitlab = Application.get_env(:robine, :gitlab_webhook_secret)
    previous_forgejo = Application.get_env(:robine, :forgejo_webhook_secret)
    Application.put_env(:robine, :gitlab_webhook_secret, "gitlab-webhook-test-secret")
    Application.put_env(:robine, :forgejo_webhook_secret, "forgejo-webhook-test-secret")

    on_exit(fn ->
      restore(:gitlab_webhook_secret, previous_gitlab)
      restore(:forgejo_webhook_secret, previous_forgejo)
    end)

    :ok
  end

  test "GitLab authenticates the raw body and namespaces duplicate delivery identity", %{
    conn: conn
  } do
    body = Jason.encode!(%{"object_kind" => "push"})
    external_id = "shared-delivery-1"

    accepted =
      conn
      |> json_headers()
      |> put_req_header("x-gitlab-event-uuid", external_id)
      |> put_req_header("x-gitlab-event", "Push Hook")
      |> put_req_header("x-gitlab-token", "gitlab-webhook-test-secret")
      |> post(~p"/api/gitlab/webhooks", body)

    assert accepted.status == 202

    delivery = Repo.one!(from stored in GitHubDelivery, where: stored.provider == :gitlab)
    assert delivery.provider_instance == "default"
    assert delivery.provider_delivery_id == external_id
    assert delivery.id != external_id
    assert_enqueued(worker: ProcessGitHubDeliveryWorker, args: %{delivery_id: delivery.id})

    duplicate =
      build_conn()
      |> json_headers()
      |> put_req_header("x-gitlab-event-uuid", external_id)
      |> put_req_header("x-gitlab-event", "Push Hook")
      |> put_req_header("x-gitlab-token", "gitlab-webhook-test-secret")
      |> post(~p"/api/gitlab/webhooks", body)

    assert duplicate.status == 200
  end

  test "Forgejo verifies HMAC-SHA256 before persistence", %{conn: conn} do
    body = Jason.encode!(%{"action" => "opened"})

    signature =
      :crypto.mac(:hmac, :sha256, "forgejo-webhook-test-secret", body)
      |> Base.encode16(case: :lower)

    accepted =
      conn
      |> json_headers()
      |> put_req_header("x-forgejo-delivery", "forgejo-delivery-1")
      |> put_req_header("x-forgejo-event", "pull_request")
      |> put_req_header("x-forgejo-signature", signature)
      |> post(~p"/api/forgejo/webhooks", body)

    assert accepted.status == 202

    assert Repo.aggregate(
             from(stored in GitHubDelivery, where: stored.provider == :forgejo),
             :count
           ) == 1

    rejected =
      build_conn()
      |> json_headers()
      |> put_req_header("x-forgejo-delivery", "forgejo-delivery-2")
      |> put_req_header("x-forgejo-event", "push")
      |> put_req_header("x-forgejo-signature", String.duplicate("0", 64))
      |> post(~p"/api/forgejo/webhooks", body)

    assert rejected.status == 401

    assert Repo.aggregate(
             from(stored in GitHubDelivery, where: stored.provider == :forgejo),
             :count
           ) == 1
  end

  defp json_headers(conn), do: put_req_header(conn, "content-type", "application/json")
  defp restore(key, nil), do: Application.delete_env(:robine, key)
  defp restore(key, value), do: Application.put_env(:robine, key, value)
end
