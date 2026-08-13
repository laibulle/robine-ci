defmodule Robine.Adapters.Runner.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Runner.Capabilities

  test "selects native execution and stable labels for Apple Silicon macOS" do
    assert %{
             "os" => "macos",
             "architecture" => "arm64",
             "native" => true,
             "docker" => false,
             "executor" => "native"
           } = Capabilities.detect({:unix, :darwin}, "aarch64-apple-darwin24.0.0")
  end

  test "keeps Linux runners on Docker and normalizes x86-64" do
    assert %{
             "os" => "linux",
             "architecture" => "amd64",
             "native" => false,
             "docker" => true,
             "executor" => "docker"
           } = Capabilities.detect({:unix, :linux}, "x86_64-pc-linux-gnu")
  end
end
