defmodule Robine.Release.LicensingTest do
  use ExUnit.Case, async: true

  test "ships the complete AGPL network-use terms" do
    license = File.read!("LICENSE")

    assert license =~ "GNU AFFERO GENERAL PUBLIC LICENSE"
    assert license =~ "13. Remote Network Interaction"
    assert license =~ "How to Apply These Terms to Your New Programs"
  end

  test "lists every locked dependency in third-party notices" do
    lock = Mix.Dep.Lock.read()
    notices = File.read!("THIRD_PARTY_NOTICES.md")

    for dependency <- Map.keys(lock) do
      assert notices =~ "| #{dependency} |",
             "THIRD_PARTY_NOTICES.md is missing locked dependency #{dependency}"
    end
  end
end
