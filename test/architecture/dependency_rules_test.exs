defmodule Robine.Architecture.DependencyRulesTest do
  use ExUnit.Case, async: true

  @domain_forbidden [
    "Ecto.",
    "Phoenix.",
    "Oban.",
    "Robine.Repo",
    "Robine.Adapters",
    "RobineWeb"
  ]

  @use_case_forbidden [
    "Ecto.",
    "Phoenix.",
    "Oban.",
    "Robine.Repo",
    "Robine.Adapters",
    "RobineWeb"
  ]

  test "domain modules do not depend on frameworks, delivery, or adapters" do
    assert_clean(Path.wildcard("lib/robine/*/domain/**/*.ex"), @domain_forbidden)
  end

  test "use cases depend on ports rather than concrete infrastructure" do
    assert_clean(Path.wildcard("lib/robine/*/use_cases/**/*.ex"), @use_case_forbidden)
  end

  test "delivery adapters do not bypass facades for use cases or persistence" do
    delivery_files =
      Path.wildcard("lib/robine_web/**/*.ex") ++ Path.wildcard("lib/robine_cli/**/*.ex")

    assert_clean(delivery_files, [
      ".UseCases.",
      "Robine.Repo",
      "Ecto.Query",
      "Adapters.Persistence.Postgres.Schemas"
    ])
  end

  test "facades use explicit defdelegate and contain no infrastructure dependencies" do
    facade_files =
      Path.wildcard("lib/robine/*.ex")
      |> Enum.reject(
        &(&1 in [
            "lib/robine/application.ex",
            "lib/robine/execution_context.ex",
            "lib/robine/mailer.ex",
            "lib/robine/repo.ex"
          ])
      )

    assert_clean(facade_files, ["Robine.Adapters", "Robine.Repo", "Ecto.", "Phoenix.", "Oban."])

    for file <- facade_files do
      source = File.read!(file)

      assert source =~ "defdelegate",
             "#{file} must expose operations through explicit defdelegate"
    end
  end

  defp assert_clean(files, forbidden_tokens) do
    violations =
      for file <- files,
          token <- forbidden_tokens,
          source = File.read!(file),
          String.contains?(source, token) do
        "#{file} contains forbidden dependency #{inspect(token)}"
      end

    assert violations == [], Enum.join(violations, "\n")
  end
end
