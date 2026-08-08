defmodule Robine.Secrets.UseCases.RedactOutput do
  @moduledoc "Redacts literal and base64-encoded secret values from output."
  alias Robine.Secrets.Domain.Redactor

  @spec call(map()) :: {:ok, String.t()} | {:error, term()}
  def call(%{output: output, values: values}) when is_binary(output) and is_list(values) do
    with {:ok, redactor} <- Redactor.new(values),
         {emitted, redactor} <- Redactor.push(redactor, output) do
      {:ok, emitted <> Redactor.finish(redactor)}
    end
  end

  def call(_input), do: {:error, :invalid_redaction_input}
end
