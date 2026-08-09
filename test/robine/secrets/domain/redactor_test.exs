defmodule Robine.Secrets.Domain.RedactorTest do
  use ExUnit.Case, async: true
  alias Robine.Secrets.Domain.Redactor

  test "redacts literal secrets split across arbitrary chunks" do
    secret = "super-secret-value"
    {:ok, redactor} = Redactor.new([secret])
    {first, redactor} = Redactor.push(redactor, "before super-")
    {second, redactor} = Redactor.push(redactor, "secret-")
    {third, redactor} = Redactor.push(redactor, "value after")
    output = first <> second <> third <> Redactor.finish(redactor)
    assert output == "before [REDACTED] after"
    refute output =~ secret
  end

  test "redacts every documented encoded variant across chunk boundaries" do
    secret = ">>>>>>>>"

    for variant <- Robine.Secrets.Domain.ValuePolicy.variants(secret) do
      split_at = max(div(byte_size(variant), 2), 1)
      <<first::binary-size(^split_at), second::binary>> = variant
      {:ok, redactor} = Redactor.new([secret])
      {prefix, redactor} = Redactor.push(redactor, "encoded=#{first}")
      {suffix, redactor} = Redactor.push(redactor, second)

      assert prefix <> suffix <> Redactor.finish(redactor) == "encoded=[REDACTED]"
    end
  end

  test "rejects values outside the masking bounds" do
    assert {:error, :secret_too_short} = Redactor.new(["short"])
    assert {:error, :secret_too_large} = Redactor.new([:binary.copy("a", 65_537)])
  end

  test "debug inspection never renders secret patterns or buffered fragments" do
    secret = "inspection-fixture-secret"
    {:ok, redactor} = Redactor.new([secret])
    {_output, redactor} = Redactor.push(redactor, "inspection-fixture-")

    refute inspect(redactor) =~ secret
    refute inspect(redactor) =~ "inspection-fixture-"
  end
end
