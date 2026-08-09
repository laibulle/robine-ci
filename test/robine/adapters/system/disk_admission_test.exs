defmodule Robine.Adapters.System.DiskAdmissionTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.System.DiskAdmission

  test "parses POSIX df capacity without depending on the mount path" do
    output = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk 10000000 7500000 2500000 75% /path with spaces
    """

    assert {:ok, %{available_bytes: 2_560_000_000, used_percent: 75}} =
             DiskAdmission.parse_df(output)
  end

  test "rejects malformed output" do
    assert {:error, :invalid_df_output} = DiskAdmission.parse_df("not df")
  end
end
