defmodule Robine.Secrets.Domain.ValuePolicyTest do
  use ExUnit.Case, async: true

  alias Robine.Secrets.Domain.ValuePolicy

  test "accepts only binary values between 8 bytes and 64 KiB" do
    assert :ok = ValuePolicy.validate(:binary.copy("a", 8))
    assert :ok = ValuePolicy.validate(:binary.copy("a", 65_536))
    assert {:error, :not_binary} = ValuePolicy.validate(nil)
    assert {:error, :secret_too_short} = ValuePolicy.validate(:binary.copy("a", 7))
    assert {:error, :secret_too_large} = ValuePolicy.validate(:binary.copy("a", 65_537))
  end

  test "derives literal, base64, base64url, and byte-wise percent-encoded variants" do
    secret = ">>>>>>>>"
    variants = ValuePolicy.variants(secret)

    assert secret in variants
    assert Base.encode64(secret) in variants
    assert Base.encode64(secret, padding: false) in variants
    assert Base.url_encode64(secret) in variants
    assert Base.url_encode64(secret, padding: false) in variants
    assert "%3E%3E%3E%3E%3E%3E%3E%3E" in variants
  end
end
