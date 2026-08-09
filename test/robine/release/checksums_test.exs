defmodule Robine.Release.ChecksumsTest do
  use ExUnit.Case, async: true

  alias Robine.Release.{Checksums, Package}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "robine-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "packages a versioned executable and verifies its strict manifest", %{directory: directory} do
    source = Path.join(directory, "source-escript")
    output = Path.join(directory, "dist")
    File.write!(source, "#!/usr/bin/env escript\nmain(_) -> ok.\n")

    assert {:ok, %{artifact: artifact, native_artifacts: native, manifest: manifest}} =
             Package.create(source, output, "1.2.3-rc.1+build.7")

    assert Path.basename(artifact) == "robine-1.2.3-rc.1+build.7.escript"
    assert File.stat!(artifact).access == :read_write

    assert Enum.map(native, &Path.basename/1) |> Enum.sort() ==
             ~w(robine-exile-spawner robine-exile.app robine-exile.so)

    assert :ok = Checksums.verify(manifest, output)

    expected = :crypto.hash(:sha256, File.read!(artifact)) |> Base.encode16(case: :lower)
    assert File.read!(manifest) =~ "#{expected}  #{Path.basename(artifact)}\n"
    assert length(String.split(File.read!(manifest), "\n", trim: true)) == 4

    File.write!(artifact, "tampered")
    assert {:error, {:checksum_mismatch, [name]}} = Checksums.verify(manifest, output)
    assert name == Path.basename(artifact)
  end

  test "writes artifacts in deterministic name order and rejects unsafe manifests", %{
    directory: directory
  } do
    first = Path.join(directory, "zeta.escript")
    second = Path.join(directory, "alpha.escript")
    manifest = Path.join(directory, "SHA256SUMS")
    File.write!(first, "zeta")
    File.write!(second, "alpha")

    assert {:ok, ^manifest} = Checksums.write([first, second], manifest)
    assert [alpha, zeta] = String.split(File.read!(manifest), "\n", trim: true)
    assert alpha =~ "  alpha.escript"
    assert zeta =~ "  zeta.escript"

    File.write!(manifest, "#{String.duplicate("0", 64)}  ../escape\n")
    assert {:error, :invalid_checksum_manifest} = Checksums.verify(manifest, directory)
  end
end
