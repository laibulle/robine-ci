defmodule Robine.Transfers.CreateSourceArchiveTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Archive.SafeTar
  alias Robine.ExecutionContext
  alias Robine.Transfers
  alias Robine.Transfers.Dependencies

  test "accepts the provider file list and retains executable source files" do
    context =
      ExecutionContext.new(
        %{id: "admin", role: :administrator},
        "source-archive-test",
        %{transfers: %Dependencies{archive: SafeTar}}
      )

    files = [%{path: "scripts/build.sh", content: "#!/bin/sh\n", mode: 0o100755}]

    assert {:ok, archive} = Transfers.create_source_archive(%{files: files}, context)
    assert {:ok, [%{path: "scripts/build.sh", mode: 0o755}]} = SafeTar.extract_source(archive)
  end
end
