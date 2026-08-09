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

  @pure_call_one_exceptions [
    "Robine.Execution.UseCases.EvaluateJobCondition",
    "Robine.Workflows.UseCases.EvaluateSchedule",
    "Robine.Workflows.UseCases.PrepareManualRun",
    "Robine.Secrets.UseCases.RedactOutput",
    "Robine.Secrets.UseCases.ValidateValues"
  ]

  test "domain modules do not depend on frameworks, delivery, or adapters" do
    assert_clean(Path.wildcard("lib/robine/*/domain/**/*.ex"), @domain_forbidden)
  end

  test "use cases depend on ports rather than concrete infrastructure" do
    assert_clean(Path.wildcard("lib/robine/*/use_cases/**/*.ex"), @use_case_forbidden)
  end

  test "delivery adapters do not bypass facades for use cases or persistence" do
    delivery_files =
      Path.wildcard("lib/robine_web/**/*.ex") ++
        Path.wildcard("lib/robine_cli/**/*.ex") ++
        Path.wildcard("lib/robine/adapters/background/**/*.ex")

    assert_clean(delivery_files, [
      ".UseCases.",
      "Robine.Repo",
      "Ecto.Query",
      "Adapters.Persistence.Postgres.Schemas"
    ])

    assert_clean(
      Path.wildcard("lib/robine_web/**/*.ex") ++ Path.wildcard("lib/robine_cli/**/*.ex"),
      ["Robine.Adapters"]
    )
  end

  test "bounded contexts do not reach into another context's internals" do
    files =
      Path.wildcard("lib/robine/*/domain/**/*.ex") ++
        Path.wildcard("lib/robine/*/use_cases/**/*.ex")

    violations = Enum.flat_map(files, &cross_context_violations/1)

    assert violations == [], Enum.join(violations, "\n")
  end

  test "negative fixtures prove every dependency direction is rejected" do
    fixture_cases = [
      {"domain_to_framework.txt", @domain_forbidden},
      {"use_case_to_adapter.txt", @use_case_forbidden},
      {"delivery_to_use_case.txt", [".UseCases."]},
      {"delivery_to_persistence.txt", ["Robine.Repo"]},
      {"facade_to_infrastructure.txt", ["Oban."]}
    ]

    for {fixture, forbidden} <- fixture_cases do
      path = Path.join("test/fixtures/architecture", fixture)

      assert violations([path], forbidden) != [],
             "#{path} must demonstrate a rejected dependency"
    end

    assert cross_context_violations("test/fixtures/architecture/cross_context_internal.txt") != []
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

  test "every use case is documented and exposed by exactly one facade delegate" do
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

    delegates = Enum.flat_map(facade_files, &facade_delegates/1)

    use_cases =
      Path.wildcard("lib/robine/*/use_cases/*.ex")
      |> Enum.map(fn path ->
        source = File.read!(path)

        assert [_, module] =
                 Regex.run(~r/defmodule (Robine\.[A-Za-z]+\.UseCases\.[A-Za-z]+)/, source)

        module
      end)

    assert Enum.sort(delegates) == Enum.sort(use_cases)
    assert length(Enum.uniq(delegates)) == length(delegates)
  end

  test "CLI dependency selection stays in the runtime composition root" do
    source = File.read!("lib/robine/adapters/cli.ex")

    refute source =~ "Robine.Adapters.Workflow"
    refute source =~ "Robine.Adapters.Execution"
    assert source =~ "RuntimeDependencies.local_context()"
  end

  test "storage retention depends on the blob-store port rather than a concrete backend" do
    source = File.read!("lib/robine/adapters/persistence/postgres/storage_retention.ex")

    refute source =~ "LocalBlobStore"
    refute source =~ "S3BlobStore"
    assert source =~ "blob_store.inventory()"
    assert source =~ "blob_store.delete("
  end

  test "use cases expose call/2 except for the explicit pure call/1 allowlist" do
    for path <- Path.wildcard("lib/robine/*/use_cases/*.ex") do
      source = File.read!(path)
      assert [_, name] = Regex.run(~r/defmodule (Robine\.[A-Za-z]+\.UseCases\.[A-Za-z]+)/, source)
      module = String.to_existing_atom("Elixir." <> name)
      functions = module.__info__(:functions)

      if name in @pure_call_one_exceptions do
        assert {:call, 1} in functions
        refute source =~ "ExecutionContext"
        refute source =~ ".Ports."
        refute source =~ ".Dependencies"
      else
        assert {:call, 2} in functions, "#{name} must expose call/2"
      end
    end
  end

  defp assert_clean(files, forbidden_tokens) do
    found = violations(files, forbidden_tokens)

    assert found == [], Enum.join(found, "\n")
  end

  defp violations(files, forbidden_tokens) do
    for file <- files,
        token <- forbidden_tokens,
        source = File.read!(file) |> String.replace("Robine.Repositories", "RepositoriesContext"),
        String.contains?(source, token) do
      "#{file} contains forbidden dependency #{inspect(token)}"
    end
  end

  defp cross_context_violations(file) do
    source_context =
      case Regex.run(~r{(?:lib|fixtures)/robine/([^/]+)/(?:domain|use_cases)/}, file) do
        [_, context] -> Macro.camelize(context)
        nil -> "Pipelines"
      end

    File.read!(file)
    |> then(&Regex.scan(~r/Robine\.([A-Z][A-Za-z]+)\.(?:Domain|UseCases|Ports|Dependencies)/, &1))
    |> Enum.flat_map(fn [dependency, target_context] ->
      if target_context == source_context do
        []
      else
        ["#{file} reaches into another context through #{dependency}"]
      end
    end)
  end

  defp facade_delegates(path) do
    source = File.read!(path)
    assert [_, context] = Regex.run(~r/defmodule Robine\.([A-Za-z]+) do/, source)

    delegate_count = length(Regex.scan(~r/\bdefdelegate\s/, source))
    spec_count = length(Regex.scan(~r/^\s*@spec\s/m, source))
    call_delegate_count = length(Regex.scan(~r/as:\s*:call/, source))
    assert delegate_count == spec_count, "#{path} must document every delegate with one @spec"
    assert delegate_count == call_delegate_count, "#{path} delegates must target call"

    Regex.scan(~r/to:\s*UseCases\.([A-Za-z]+)/, source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&"Robine.#{context}.UseCases.#{&1}")
  end
end
