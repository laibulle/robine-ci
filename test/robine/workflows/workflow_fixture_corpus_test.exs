defmodule Robine.Workflows.WorkflowFixtureCorpusTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.CLI
  alias Robine.ExecutionContext
  alias Robine.Workflows
  alias Robine.Workflows.Dependencies

  @root Path.expand("../../fixtures/workflows", __DIR__)

  test "server and CLI produce identical results for the shared corpus" do
    manifest = @root |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    for {relative, expectation} <- Enum.sort(manifest) do
      path = Path.join(@root, relative)
      source = File.read!(path)
      server = Workflows.validate(%{source: source, path: path}, context())
      {cli_status, cli_json} = CLI.run(["validate", path, "--format", "json"], @root)
      cli = Jason.decode!(cli_json)

      if expectation["valid"] do
        assert {:ok, _validated} = server
        assert cli_status == 0
        assert cli["valid"] == true
      else
        assert {:error, diagnostics} = server
        assert cli_status == 2
        assert cli["valid"] == false
        assert Enum.map(diagnostics, & &1.code) == expectation["codes"]
        assert Enum.map(cli["diagnostics"], &projection/1) == Enum.map(diagnostics, &projection/1)
        assert Enum.all?(diagnostics, &(is_integer(&1.line) and is_integer(&1.column)))
      end
    end
  end

  defp projection(%{code: code, path: path, line: line, column: column}),
    do: %{code: code, path: path, line: line, column: column}

  defp projection(%{"code" => code, "path" => path, "line" => line, "column" => column}),
    do: %{code: code, path: path, line: line, column: column}

  defp context do
    ExecutionContext.new(%{id: "fixture", role: :maintainer}, "fixture", %{
      workflows: %Dependencies{decoder: Robine.Adapters.Workflow.YamlDecoder}
    })
  end
end
