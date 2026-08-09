defmodule Robine.Repositories.CoverageReportTest do
  use ExUnit.Case, async: true

  alias Robine.Repositories.Domain.CoverageReport

  test "parses a bounded workflow coverage marker" do
    assert {:ok, report} =
             CoverageReport.parse(
               "before\nROBINE_COVERAGE total=75.3 threshold=75 report=coverage-report\n"
             )

    assert report.total == "75.3"
    assert report.total_value == 75.3
    assert report.threshold == "75"
    assert report.threshold_value == 75.0
    assert report.report == "coverage-report"
  end

  test "rejects malformed and out-of-range markers" do
    assert :error = CoverageReport.parse("ROBINE_COVERAGE total=101 threshold=75 report=coverage")
    assert :error = CoverageReport.parse("ROBINE_COVERAGE total=75 threshold=-1 report=coverage")
    assert :error = CoverageReport.parse("ROBINE_COVERAGE total=75 threshold=75 report=../escape")
    assert :error = CoverageReport.parse("coverage 75%")
  end
end
