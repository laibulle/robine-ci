defmodule Robine.Workflows.Domain.CronExpressionTest do
  use ExUnit.Case, async: true

  alias Robine.Workflows.Domain.CronExpression

  test "matches UTC wildcards, lists, ranges, and steps" do
    assert {:ok, expression} = CronExpression.parse("*/15 9-17 * 1,6 1-5")
    assert {:ok, offset} = CronExpression.parse("5/20 * * * *")

    assert CronExpression.matches?(expression, ~U[2026-06-01 09:30:00Z])
    assert CronExpression.matches?(expression, ~U[2026-06-05 17:45:59Z])
    refute CronExpression.matches?(expression, ~U[2026-06-06 09:30:00Z])
    refute CronExpression.matches?(expression, ~U[2026-06-01 09:31:00Z])
    refute CronExpression.matches?(expression, ~U[2026-05-01 09:30:00Z])
    assert CronExpression.matches?(offset, ~U[2026-06-01 09:25:00Z])
    refute CronExpression.matches?(offset, ~U[2026-06-01 09:20:00Z])
  end

  test "normalizes both weekday Sunday values" do
    assert {:ok, zero} = CronExpression.parse("0 0 * * 0")
    assert {:ok, seven} = CronExpression.parse("0 0 * * 7")
    sunday = ~U[2026-06-07 00:00:00Z]

    assert CronExpression.matches?(zero, sunday)
    assert CronExpression.matches?(seven, sunday)
    refute CronExpression.matches?(zero, ~U[2026-06-08 00:00:00Z])
  end

  test "uses conventional OR semantics when both day fields are restricted" do
    assert {:ok, expression} = CronExpression.parse("0 12 1 * 1")

    assert CronExpression.matches?(expression, ~U[2026-06-01 12:00:00Z])
    assert CronExpression.matches?(expression, ~U[2026-07-01 12:00:00Z])
    assert CronExpression.matches?(expression, ~U[2026-06-08 12:00:00Z])
    refute CronExpression.matches?(expression, ~U[2026-06-02 12:00:00Z])
  end

  test "rejects macros, names, malformed fields, invalid bounds, and invalid steps" do
    invalid = [
      "@daily",
      "0 0 * *",
      "0 0 * JAN *",
      "60 0 * * *",
      "0 24 * * *",
      "0 0 0 * *",
      "0 0 * 13 *",
      "0 0 * * 8",
      "*/0 * * * *",
      "5-2 * * * *",
      "1,,2 * * * *"
    ]

    for cron <- invalid do
      assert {:error, :invalid_cron} = CronExpression.parse(cron), cron
    end
  end
end
