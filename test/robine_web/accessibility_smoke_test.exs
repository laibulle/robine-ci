defmodule RobineWeb.AccessibilitySmokeTest do
  use RobineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Robine.Pipelines
  alias Robine.Runtime.Dependencies

  test "core setup, sign-in, navigation, and pipeline journeys pass semantic checks", %{
    conn: conn
  } do
    conn |> get(~p"/setup") |> html_response(200) |> audit_page("first-run setup")
    conn |> recycle() |> get(~p"/sign-in") |> html_response(200) |> audit_page("sign-in")

    conn = signed_in_conn(conn)
    context = Dependencies.context(%{id: "admin", role: :administrator}, "accessibility")

    assert {:ok, pipeline} =
             Pipelines.create_pipeline(
               %{
                 repository_id: Ecto.UUID.generate(),
                 workflow_name: "Accessible CI",
                 commit_sha: String.duplicate("a", 40),
                 jobs: %{"test" => %{needs: []}}
               },
               context
             )

    assert {:ok, _index, index_html} = live(conn, ~p"/pipelines")
    audit_page(index_html, "pipeline history")

    assert {:ok, _show, show_html} = live(conn, ~p"/pipelines/#{pipeline.id}")
    audit_page(show_html, "pipeline detail")

    document = LazyHTML.from_fragment(show_html)
    assert count(document, "[aria-label='Status: created']") == 1
    assert count(document, "ol[aria-label='Pipeline jobs']") == 1
  end

  defp audit_page(html, journey) do
    document = LazyHTML.from_fragment(html)

    assert count(document, "main") == 1, "#{journey} must expose exactly one main landmark"
    assert count(document, "h1") == 1, "#{journey} must expose exactly one page heading"

    assert count(document, "nav:not([aria-label])") == 0,
           "#{journey} navigation landmarks must have an accessible name"

    ids = LazyHTML.attribute(LazyHTML.query(document, "[id]"), "id")
    assert length(ids) == length(Enum.uniq(ids)), "#{journey} contains duplicate element IDs"

    assert_accessible_names(document, "button", journey)
    assert_accessible_names(document, "a[href]", journey)

    controls = count(document, "input:not([type='hidden']), select, textarea")

    wrapped_controls =
      count(document, "label input:not([type='hidden']), label select, label textarea")

    explicitly_labelled =
      count(document, "input[aria-label], select[aria-label], textarea[aria-label]")

    assert wrapped_controls + explicitly_labelled >= controls,
           "#{journey} contains a form control without an accessible label"

    images = count(document, "img")
    assert count(document, "img[alt]") == images, "#{journey} contains an image without alt text"
  end

  defp assert_accessible_names(document, selector, journey) do
    document
    |> LazyHTML.query(selector)
    |> Enum.each(fn element ->
      text = element |> LazyHTML.text() |> String.trim()
      aria_label = LazyHTML.attribute(element, "aria-label")

      assert text != "" or aria_label != [],
             "#{journey} contains an unnamed #{selector} control"
    end)
  end

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp signed_in_conn(conn) do
    post(conn, ~p"/setup", %{
      "token" => "test-bootstrap-token",
      "email" => "admin@example.com",
      "password" => "a secure password"
    })
  end
end
