defmodule Robine.Secrets do
  @moduledoc "Public application API for encrypted secrets and output redaction."

  alias Robine.ExecutionContext
  alias Robine.Secrets.Contracts.SecretMetadata
  alias Robine.Secrets.UseCases

  @spec store_secret(map(), ExecutionContext.t()) :: {:ok, SecretMetadata.t()} | {:error, term()}
  defdelegate store_secret(input, context), to: UseCases.StoreSecret, as: :call

  @spec resolve_secrets(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_secrets(input, context), to: UseCases.ResolveSecrets, as: :call

  @spec redact_output(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate redact_output(input), to: UseCases.RedactOutput, as: :call

  @spec list_secrets(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_secrets(input, context), to: UseCases.ListSecrets, as: :call
end
