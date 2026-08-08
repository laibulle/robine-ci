defmodule Robine.Secrets.UseCases.ResolveSecrets do
  @moduledoc "Resolves explicitly named values for one authorized repository job."

  alias Robine.ExecutionContext
  alias Robine.Secrets.Dependencies
  alias Robine.Secrets.Domain.Secret

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(%{repository_id: repository_id, names: names}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{secrets: %Dependencies{} = dependencies}
      })
      when is_binary(repository_id) and is_list(names) do
    with true <- Enum.all?(names, &is_binary/1),
         {:ok, secrets} <-
           dependencies.repository.find_authorized(repository_id, Enum.uniq(names)),
         :ok <- ensure_complete(names, secrets),
         {:ok, values} <- decrypt_all(secrets, dependencies.cipher) do
      {:ok, values}
    else
      false -> {:error, {:invalid_secret_reference, :names}}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp ensure_complete(names, secrets) do
    missing = Enum.uniq(names) -- Enum.map(secrets, & &1.name)
    if missing == [], do: :ok, else: {:error, {:secrets_missing, missing}}
  end

  defp decrypt_all(secrets, cipher) do
    Enum.reduce_while(secrets, {:ok, %{}}, fn %Secret{} = secret, {:ok, values} ->
      case cipher.decrypt(Map.from_struct(secret), Secret.aad(secret)) do
        {:ok, plaintext} -> {:cont, {:ok, Map.put(values, secret.name, plaintext)}}
        {:error, reason} -> {:halt, {:error, {:secret_decryption_failed, secret.name, reason}}}
      end
    end)
  end
end
