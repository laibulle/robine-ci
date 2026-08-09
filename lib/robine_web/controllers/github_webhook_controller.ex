defmodule RobineWeb.GitHubWebhookController do
  use RobineWeb, :controller

  alias Robine.Repositories
  alias Robine.Observability.Log
  alias Robine.Runtime.Dependencies

  def create(conn, _params) do
    delivery_id = get_req_header(conn, "x-github-delivery") |> List.first()
    event = get_req_header(conn, "x-github-event") |> List.first()
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()
    raw_body = conn.private[:raw_body] || <<>>

    context =
      Dependencies.context(
        %{id: "system:github-webhook", role: :administrator},
        delivery_id || Ecto.UUID.generate()
      )

    result =
      Repositories.accept_github_webhook(
        %{delivery_id: delivery_id, event: event, signature: signature, body: raw_body},
        context
      )

    Log.event(log_level(result), "github.webhook.received", %{
      correlation_id: context.correlation_id,
      delivery_id: delivery_id,
      github_event: event,
      outcome: outcome(result)
    })

    case result do
      {:ok, :accepted} ->
        conn |> put_status(:accepted) |> json(%{status: "accepted"})

      {:ok, :duplicate} ->
        conn |> put_status(:ok) |> json(%{status: "duplicate"})

      {:error, :invalid_signature} ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid signature"})

      {:error, {:invalid_webhook, reason}} ->
        conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "temporarily unavailable"})
    end
  end

  defp log_level({:ok, _result}), do: :info
  defp log_level({:error, _reason}), do: :warning
  defp outcome({:ok, result}), do: result
  defp outcome({:error, :invalid_signature}), do: :invalid_signature
  defp outcome({:error, _reason}), do: :error
end
