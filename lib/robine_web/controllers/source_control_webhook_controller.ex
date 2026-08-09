defmodule RobineWeb.SourceControlWebhookController do
  use RobineWeb, :controller

  alias Robine.Observability.Log
  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  def gitlab(conn, _params),
    do:
      receive_webhook(conn, :gitlab,
        delivery: "x-gitlab-event-uuid",
        event: "x-gitlab-event",
        authentication: "x-gitlab-token"
      )

  def forgejo(conn, _params),
    do:
      receive_webhook(conn, :forgejo,
        delivery: "x-forgejo-delivery",
        event: "x-forgejo-event",
        authentication: "x-forgejo-signature"
      )

  defp receive_webhook(conn, provider, headers) do
    started = System.monotonic_time()
    delivery_id = header(conn, headers[:delivery])
    event = header(conn, headers[:event])
    authentication = header(conn, headers[:authentication])
    raw_body = conn.private[:raw_body] || <<>>

    context =
      Dependencies.context(
        %{id: "system:#{provider}-webhook", role: :administrator},
        delivery_id || Ecto.UUID.generate()
      )

    result =
      Repositories.accept_source_control_webhook(
        %{
          provider: provider,
          provider_instance: "default",
          delivery_id: delivery_id,
          event: event,
          authentication: authentication,
          body: raw_body
        },
        context
      )

    outcome = outcome(result)

    Log.event(log_level(result), "source_control.webhook.received", %{
      correlation_id: context.correlation_id,
      delivery_id: delivery_id,
      provider: provider,
      outcome: outcome
    })

    :telemetry.execute(
      [:robine, :source_control, :webhook],
      %{count: 1, duration: System.monotonic_time() - started},
      %{provider: provider, outcome: outcome, event: bounded_event(provider, event)}
    )

    respond(conn, result)
  end

  defp respond(conn, {:ok, :accepted}),
    do: conn |> put_status(:accepted) |> json(%{status: "accepted"})

  defp respond(conn, {:ok, :duplicate}),
    do: conn |> put_status(:ok) |> json(%{status: "duplicate"})

  defp respond(conn, {:error, :invalid_signature}),
    do: conn |> put_status(:unauthorized) |> json(%{error: "invalid signature"})

  defp respond(conn, {:error, {:invalid_webhook, reason}}),
    do: conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})

  defp respond(conn, {:error, _reason}),
    do: conn |> put_status(:service_unavailable) |> json(%{error: "temporarily unavailable"})

  defp header(conn, name), do: get_req_header(conn, name) |> List.first()
  defp log_level({:ok, _result}), do: :info
  defp log_level({:error, _reason}), do: :warning
  defp outcome({:ok, result}), do: result
  defp outcome({:error, :invalid_signature}), do: :invalid_signature
  defp outcome({:error, _reason}), do: :error

  defp bounded_event(:gitlab, event) when event in ["Push Hook", "Merge Request Hook"],
    do: if(event == "Push Hook", do: :push, else: :merge_request)

  defp bounded_event(:forgejo, "push"), do: :push
  defp bounded_event(:forgejo, "pull_request"), do: :pull_request

  defp bounded_event(_provider, _event), do: :other
end
