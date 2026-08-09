defmodule Robine.Execution.RunnerTemplateTest do
  use ExUnit.Case, async: true

  alias Robine.Execution.Domain.RunnerTemplate

  test "resolves only allowlisted OS and architecture variables" do
    platform = RunnerTemplate.platform()
    expected = "release-#{platform.os}-#{platform.arch}"

    assert {:ok, ^expected} =
             RunnerTemplate.resolve("release-${{ runner.os }}-${{ runner.arch }}")

    assert {:error, :unsupported_runner_template} =
             RunnerTemplate.resolve("release-${{ env.SECRET }}")
  end
end
