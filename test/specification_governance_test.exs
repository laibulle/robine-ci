defmodule Robine.SpecificationGovernanceTest do
  use ExUnit.Case, async: true

  @states ~w(Accepted Implementing Shipped Deprecated)
  @targets ["MVP", "Post-MVP"]
  @required_sections [
    "## Status",
    "## Summary",
    "## Problem",
    "## Goals",
    "## Non-goals",
    "## Requirements",
    "## Proposed design",
    "## Failure modes and recovery",
    "## Security and privacy",
    "## Observability",
    "## Acceptance criteria",
    "## Open questions",
    "## Out of scope / future work"
  ]

  test "every specification has an accepted lifecycle, target, structure, and aligned filename" do
    specifications = Path.wildcard("docs/specs/*/*.md")
    assert specifications != []

    ids = Enum.map(specifications, &validate_specification!/1)
    assert Enum.uniq(ids) == ids, "specification IDs must be unique"
  end

  test "every specification referenced by the implementation plan exists" do
    task_plan = File.read!("TASKS.md")

    referenced_paths =
      Regex.scan(~r{\((docs/specs/[^)]+\.md)\)}, task_plan, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert referenced_paths != []

    for path <- referenced_paths do
      assert File.regular?(path), "TASKS.md references missing specification #{path}"
    end
  end

  defp validate_specification!(path) do
    source = File.read!(path)

    basename = Path.basename(path)
    assert [_, basename_id] = Regex.run(~r/\A([a-z]+-[0-9]+)-/, basename)
    basename_id = String.upcase(basename_id)

    assert [_, document_id] = Regex.run(~r/\A# ([A-Z]+-[0-9]+) — /, source)
    assert document_id == basename_id, "#{path} ID does not match its filename"

    assert [_, state] = Regex.run(~r/^- \*\*State:\*\* ([A-Za-z]+)$/m, source)
    assert state in @states, "#{path} remains Draft or has an unknown lifecycle state"

    assert [_, target] = Regex.run(~r/^- \*\*Target:\*\* (.+)$/m, source)
    assert target in @targets, "#{path} has unknown target #{target}"

    for section <- @required_sections do
      assert source =~ section, "#{path} is missing #{section}"
    end

    document_id
  end
end
