defmodule Robine.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Robine.BuildInfo

  test "exposes a complete compile-time support contract" do
    info = BuildInfo.current(%{})

    assert is_binary(info.version)
    assert is_binary(info.commit_sha)
    assert is_binary(info.ref_name)
    assert is_binary(info.ref_type)
    assert is_binary(info.built_at)
    assert is_binary(info.pipeline_id)
    assert is_binary(info.trigger)
    assert is_boolean(info.release?)
    assert is_binary(info.short_commit)
    assert is_binary(info.display_ref)
  end

  test "exposes visible placeholder provenance in development" do
    info = BuildInfo.current(%{})

    refute info.release?
    assert info.commit_sha == String.pad_trailing("dev", 40, "0")
    assert info.short_commit == "dev00000"
    assert info.display_ref == "working-tree"
    assert info.built_at == "1970-01-01T00:00:00Z"
    assert info.pipeline_id == "development-local"
  end
end
