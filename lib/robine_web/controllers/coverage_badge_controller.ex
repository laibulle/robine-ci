defmodule RobineWeb.CoverageBadgeController do
  use RobineWeb, :controller

  alias Robine.Repositories
  alias Robine.Runtime.Dependencies

  def show(conn, %{"provider" => provider, "owner" => owner, "repository" => name}) do
    context =
      Dependencies.context(
        %{id: "public-coverage-badge", role: :viewer},
        conn.assigns[:request_id] || "coverage-badge"
      )

    badge = badge_for_repository(provider, owner, name, context)

    body = svg("coverage", badge.message, badge.color)

    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("cache-control", "public, max-age=60, stale-while-revalidate=300")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(:ok, body)
  end

  defp badge_for_repository(provider, owner, name, context) do
    with {:ok, repositories} <- Repositories.list_repositories(%{}, context),
         %{id: repository_id} <-
           Enum.find(repositories, fn repository ->
             to_string(repository.provider) == provider and repository.owner == owner and
               repository.name == name and repository.trusted
           end),
         {:ok, report} <- Repositories.latest_coverage(%{repository_id: repository_id}, context) do
      measured_badge(report)
    else
      _ -> %{message: "unknown", color: "#64748b"}
    end
  end

  defp measured_badge(report) do
    passed? = report.total_value >= report.threshold_value
    %{message: "#{report.total}%", color: if(passed?, do: "#059669", else: "#dc2626")}
  end

  defp svg(label, message, color) do
    label_width = 76
    message_width = max(54, String.length(message) * 8 + 16)
    width = label_width + message_width
    label_x = div(label_width, 2)
    message_x = label_width + div(message_width, 2)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="20" role="img" aria-label="#{label}: #{message}">
      <title>#{label}: #{message}</title>
      <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-opacity=".08"/></linearGradient>
      <clipPath id="r"><rect width="#{width}" height="20" rx="4"/></clipPath>
      <g clip-path="url(#r)"><rect width="#{label_width}" height="20" fill="#172033"/><rect x="#{label_width}" width="#{message_width}" height="20" fill="#{color}"/><rect width="#{width}" height="20" fill="url(#s)"/></g>
      <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
        <text x="#{label_x}" y="15" fill="#010101" fill-opacity=".3">#{label}</text><text x="#{label_x}" y="14">#{label}</text>
        <text x="#{message_x}" y="15" fill="#010101" fill-opacity=".3">#{message}</text><text x="#{message_x}" y="14">#{message}</text>
      </g>
    </svg>
    """
  end
end
