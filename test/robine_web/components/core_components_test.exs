defmodule RobineWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias RobineWeb.CoreComponents

  test "status badge exposes text and an accessible name instead of color alone" do
    html = render_component(&CoreComponents.status_badge/1, status: :runner_lost, size: "lg")

    assert html =~ ~s(aria-label="Status: runner lost")
    assert html =~ "runner lost"
    assert html =~ "badge-error"
    assert html =~ ~s(aria-hidden="true")
  end

  test "loading and degraded states expose distinct assistive semantics" do
    loading =
      render_component(&CoreComponents.ui_state/1,
        kind: :loading,
        title: "Loading pipelines"
      )

    assert loading =~ ~s(aria-busy="true")
    assert loading =~ ~s(aria-live="polite")

    degraded =
      render_component(&CoreComponents.ui_state/1,
        kind: :degraded,
        title: "GitHub unavailable"
      )

    assert degraded =~ ~s(role="alert")
    assert degraded =~ "border-warning"
  end
end
