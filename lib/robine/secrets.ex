defmodule Robine.Secrets do
  @moduledoc "Public application API for encrypted secrets and output redaction."

  alias Robine.ExecutionContext
  alias Robine.Secrets.Contracts.SecretMetadata
  alias Robine.Secrets.UseCases

  @spec store_secret(map(), ExecutionContext.t()) :: {:ok, SecretMetadata.t()} | {:error, term()}
  defdelegate store_secret(input, context), to: UseCases.StoreSecret, as: :call

  @spec resolve_secrets(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_secrets(input, context), to: UseCases.ResolveSecrets, as: :call

  @spec resolve_instance_secrets(map(), ExecutionContext.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate resolve_instance_secrets(input, context),
    to: UseCases.ResolveInstanceSecrets,
    as: :call

  @spec redact_output(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate redact_output(input), to: UseCases.RedactOutput, as: :call

  @spec validate_values(map()) :: :ok | {:error, term()}
  defdelegate validate_values(input), to: UseCases.ValidateValues, as: :call

  @spec list_secrets(map(), ExecutionContext.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_secrets(input, context), to: UseCases.ListSecrets, as: :call

  @spec rotate_keys(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  defdelegate rotate_keys(input, context), to: UseCases.RotateKeys, as: :call
end
