defmodule Robine.Autoscaling.Domain.DesiredCapacity do
  @moduledoc "Pure desired-capacity calculation with min/max enforcement."

  def calculate(policy, observed, busy, queued)
      when is_integer(observed) and observed >= 0 and is_integer(busy) and busy >= 0 and
             is_integer(queued) and queued >= 0 do
    required = busy + ceil_div(queued, policy.concurrency)
    max(policy.min_runners, min(policy.max_runners, required))
  end

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
