defmodule Robine.Adapters.Archive.SafeTarTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Archive.SafeTar

  test "accepts bounded regular files below a single archive root" do
    assert :ok = SafeTar.validate_table([entry("root/lib/app.ex", :regular, 100)], 50)

    assert :ok =
             SafeTar.validate_table(
               [entry("root", :directory, 0), entry("root/lib", :directory, 0)],
               50
             )
  end

  test "creates a deterministic-policy source archive that round-trips through validation" do
    files = %{"lib/app.ex" => "defmodule App do\nend\n", "README.md" => "hello"}

    assert {:ok, archive} = SafeTar.create_source(files)
    assert {:ok, extracted} = SafeTar.extract_source(archive)
    assert Map.new(extracted) == files
  end

  test "allows large repository archives within the bounded default" do
    assert SafeTar.max_archive_bytes() == 250_000_000

    assert {:ok, archive} = SafeTar.create_source(%{"README.md" => "hello"})

    assert {:error, :source_archive_too_large} =
             SafeTar.extract_source(archive, max_archive_bytes: byte_size(archive) - 1)
  end

  test "rejects traversal, links, devices, and other special entries" do
    assert {:error, :unsafe_source_archive_path} =
             SafeTar.validate_table([entry("root/../escape", :regular, 1)], 10)

    for type <- [:symlink, :link, :char, :block, :fifo, :unknown] do
      assert {:error, :unsupported_source_archive_entry} =
               SafeTar.validate_table([entry("root/item", type, 1)], 10)
    end
  end

  test "accepts Forgejo's bounded PAX global metadata header only by its exact name" do
    assert :ok =
             SafeTar.validate_table(
               [entry("pax_global_header", :unknown, 52), entry("root/app.ex", :regular, 10)],
               20
             )

    assert {:error, :unsupported_source_archive_entry} =
             SafeTar.validate_table([entry("root/pax_global_header", :unknown, 52)], 20)

    assert {:error, :unsupported_source_archive_entry} =
             SafeTar.validate_table([entry("pax_global_header", :unknown, 65_537)], 20)
  end

  test "enforces file count, expanded size, and compression ratio before extraction" do
    entries = [entry("root/a", :regular, 80), entry("root/b", :regular, 80)]

    assert {:error, :source_archive_limits_exceeded} =
             SafeTar.validate_table(entries, 100, max_files: 1)

    assert {:error, :source_archive_limits_exceeded} =
             SafeTar.validate_table(entries, 100, max_expanded_bytes: 100)

    assert {:error, :source_archive_limits_exceeded} =
             SafeTar.validate_table(entries, 10, max_ratio: 10)
  end

  test "applies the same attack policy to cache and artifact archives" do
    assert :ok =
             SafeTar.validate_workspace_table(
               [entry("reports/result.xml", :regular, 100)],
               50
             )

    for path <- ["../escape", "/absolute", "."] do
      assert {:error, :unsafe_workspace_archive} =
               SafeTar.validate_workspace_table([entry(path, :regular, 1)], 10)
    end

    for type <- [:symlink, :link, :char, :block, :fifo, :unknown] do
      assert {:error, :unsupported_source_archive_entry} =
               SafeTar.validate_workspace_table([entry("item", type, 1)], 10)
    end
  end

  test "bounds cache and artifact file count, expanded size, and ratio" do
    entries = [entry("a", :regular, 80), entry("b", :regular, 80)]

    assert {:error, :unsafe_workspace_archive} =
             SafeTar.validate_workspace_table(entries, 100, max_files: 1)

    assert {:error, :unsafe_workspace_archive} =
             SafeTar.validate_workspace_table(entries, 100, max_expanded_bytes: 100)

    assert {:error, :unsafe_workspace_archive} =
             SafeTar.validate_workspace_table(entries, 10, max_ratio: 10)
  end

  defp entry(path, type, size), do: {String.to_charlist(path), type, size, 0, 0o644, 0, 0}
end
