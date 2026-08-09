defmodule Robine.Adapters.CLI.LocalSourceSnapshotTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.CLI.LocalSourceSnapshot

  setup do
    directory =
      Path.join(System.tmp_dir!(), "robine-source-snapshot-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "copies tracked and visible files while excluding ignored generated symlinks", %{
    directory: directory
  } do
    git!(directory, ["init", "--quiet"])
    File.write!(Path.join(directory, ".gitignore"), "_build/\ndeps/\n")
    File.write!(Path.join(directory, "tracked.txt"), "tracked")
    File.write!(Path.join(directory, "visible.txt"), "visible")
    git!(directory, ["add", ".gitignore", "tracked.txt"])
    File.mkdir_p!(Path.join(directory, "_build/generated"))
    File.ln_s!("tracked.txt", Path.join(directory, "_build/generated/link"))

    assert {:ok, snapshot} = LocalSourceSnapshot.create(directory)
    on_exit(fn -> LocalSourceSnapshot.cleanup(snapshot) end)

    assert File.read!(Path.join(snapshot.path, "tracked.txt")) == "tracked"
    assert File.read!(Path.join(snapshot.path, "visible.txt")) == "visible"
    refute File.exists?(Path.join(snapshot.path, "_build"))
  end

  test "rejects a tracked symlink instead of following it", %{directory: directory} do
    git!(directory, ["init", "--quiet"])
    File.write!(Path.join(directory, "target.txt"), "target")
    File.ln_s!("target.txt", Path.join(directory, "linked.txt"))
    git!(directory, ["add", "linked.txt", "target.txt"])

    assert {:error, {:unsafe_local_source_entry, "linked.txt", :symlink}} =
             LocalSourceSnapshot.create(directory)
  end

  test "copies a regular non-Git directory and rejects special entries", %{
    directory: directory
  } do
    File.write!(Path.join(directory, "source.txt"), "source")
    assert {:ok, snapshot} = LocalSourceSnapshot.create(directory)
    assert File.read!(Path.join(snapshot.path, "source.txt")) == "source"
    LocalSourceSnapshot.cleanup(snapshot)

    File.ln_s!("source.txt", Path.join(directory, "linked.txt"))

    assert {:error, {:unsafe_local_source_entry, "linked.txt", :symlink}} =
             LocalSourceSnapshot.create(directory)
  end

  defp git!(directory, arguments) do
    assert {_output, 0} =
             System.cmd("git", ["-C", directory | arguments], stderr_to_stdout: true)
  end
end
