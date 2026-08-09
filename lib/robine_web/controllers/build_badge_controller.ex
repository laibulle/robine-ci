defmodule RobineWeb.BuildBadgeController do
  use RobineWeb, :controller

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  def show(conn, %{"provider" => provider, "owner" => owner, "repository" => name}) do
    context =
      Dependencies.context(
        %{id: "public-build-badge", role: :viewer},
        conn.assigns[:request_id] || "build-badge"
      )

    badge = badge_for_repository(provider, owner, name, context)

    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("cache-control", "public, max-age=30, stale-while-revalidate=120")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(:ok, svg("build", badge.message, badge.color))
  end

  defp badge_for_repository(provider, owner, name, context) do
    with {:ok, repositories} <- Repositories.list_repositories(%{}, context),
         %{id: repository_id} <-
           Enum.find(repositories, fn repository ->
             to_string(repository.provider) == provider and repository.owner == owner and
               repository.name == name and repository.trusted
           end),
         {:ok, %{status: status}} <-
           Repositories.latest_build_status(%{repository_id: repository_id}, context) do
      status_badge(status)
    else
      _ -> %{message: "unknown", color: "#64748b"}
    end
  end

  defp status_badge(:succeeded), do: %{message: "passing", color: "#059669"}
  defp status_badge(:failed), do: %{message: "failing", color: "#dc2626"}
  defp status_badge(:cancelled), do: %{message: "cancelled", color: "#64748b"}
  defp status_badge(:running), do: %{message: "running", color: "#2563eb"}

  defp status_badge(status) when status in [:created, :queued, :blocked, :preparing],
    do: %{message: to_string(status), color: "#d97706"}

  defp status_badge(_status), do: %{message: "unknown", color: "#64748b"}

  defp svg(label, message, color) do
    label_width = 52
    message_width = max(58, String.length(message) * 8 + 16)
    width = label_width + message_width

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="20" role="img" aria-label="#{label}: #{message}">
      <title>#{label}: #{message}</title>
      <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-opacity=".08"/></linearGradient>
      <clipPath id="r"><rect width="#{width}" height="20" rx="4"/></clipPath>
      <g clip-path="url(#r)"><rect width="#{label_width}" height="20" fill="#172033"/><rect x="#{label_width}" width="#{message_width}" height="20" fill="#{color}"/><rect width="#{width}" height="20" fill="url(#s)"/></g>
      <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11"><text x="#{div(label_width, 2)}" y="15" fill="#010101" fill-opacity=".3">#{label}</text><text x="#{div(label_width, 2)}" y="14">#{label}</text><text x="#{label_width + div(message_width, 2)}" y="15" fill="#010101" fill-opacity=".3">#{message}</text><text x="#{label_width + div(message_width, 2)}" y="14">#{message}</text></g>
    </svg>
    """
  end
end
