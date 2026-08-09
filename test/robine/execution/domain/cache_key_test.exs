defmodule Robine.Execution.Domain.CacheKeyTest do
  use ExUnit.Case, async: true

  alias Robine.Execution.Domain.CacheKey

  test "resolves only regular files below the exact workspace" do
    root = Path.join(System.tmp_dir!(), "robine-cache-key-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "mix.lock"), "lock-content")
    File.write!(Path.join(root, "config/runtime.exs"), "config-content")

    on_exit(fn -> File.rm_rf(root) end)

    expected =
      :crypto.hash(:sha256, "lock-content")
      |> Base.encode16(case: :lower)

    expected_key = "mix-#{expected}"
    assert {:ok, ^expected_key} = CacheKey.resolve("mix-${{ checksum('mix.lock') }}", root)

    assert {:error, {:cache_checksum, "../secret", :unsafe_path}} =
             CacheKey.resolve("${{ checksum('../secret') }}", root)

    assert {:error, {:cache_checksum, "missing", :enoent}} =
             CacheKey.resolve("${{ checksum('missing') }}", root)
  end
end
