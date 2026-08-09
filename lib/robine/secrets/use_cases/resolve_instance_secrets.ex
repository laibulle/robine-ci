defmodule Robine.Secrets.UseCases.ResolveInstanceSecrets do
  @moduledoc "Resolves encrypted instance credentials for trusted system adapters."

  alias Robine.ExecutionContext
  alias Robine.Secrets.Dependencies
  alias Robine.Secrets.Domain.Secret

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(%{names: names}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{secrets: %Dependencies{} = dependencies}
      })
      when is_list(names) do
    names = Enum.uniq(names)

    with true <- names != [] and Enum.all?(names, &is_binary/1),
         {:ok, secrets} <- dependencies.repository.find_instance(names),
         :ok <- ensure_complete(names, secrets) do
      decrypt_all(secrets, dependencies.cipher)
    else
      false -> {:error, {:invalid_secret_reference, :names}}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp ensure_complete(names, secrets) do
    missing = names -- Enum.map(secrets, & &1.name)
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
