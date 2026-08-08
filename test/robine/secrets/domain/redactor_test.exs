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

  test "redacts base64 variants and rejects dangerously short values" do
    secret = "another-secret"
    {:ok, redactor} = Redactor.new([secret])
    {output, redactor} = Redactor.push(redactor, "encoded=#{Base.encode64(secret)}")
    assert output <> Redactor.finish(redactor) == "encoded=[REDACTED]"
    assert {:error, :secret_too_short} = Redactor.new(["short"])
  end
end
