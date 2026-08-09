defmodule Robine.TestSupport.PortContracts.BlobStoreContract do
  @moduledoc false

  import ExUnit.Assertions

  def assert_contract(adapter, content \\ "blob-contract-#{Ecto.UUID.generate()}") do
    chunks = split(content)

    assert {:ok, first} = adapter.put_stream(chunks)
    assert first.size == byte_size(content)
    assert first.blob_id == first.digest
    assert {:ok, ^content} = adapter.get(first.blob_id, first.digest)

    assert {:ok, repeated} = adapter.put(content)
    assert repeated == first

    assert {:ok, %{objects: objects, unsafe: 0}} = adapter.inventory()

    assert Enum.any?(objects, fn object ->
             object.blob_id == first.blob_id and object.size == first.size
           end)

    assert :ok = adapter.delete(first.blob_id)
    assert :ok = adapter.delete(first.blob_id)
    assert {:error, :not_found} = adapter.get(first.blob_id, first.digest)
    :ok
  end

  defp split(content) do
    midpoint = div(byte_size(content), 2)

    [
      binary_part(content, 0, midpoint),
      binary_part(content, midpoint, byte_size(content) - midpoint)
    ]
  end
end
