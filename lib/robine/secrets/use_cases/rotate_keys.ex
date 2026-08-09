defmodule Robine.Secrets.UseCases.RotateKeys do
  @moduledoc "Re-encrypts a bounded resumable batch with the current key version."

  alias Robine.ExecutionContext
  alias Robine.Secrets.Dependencies
  alias Robine.Secrets.Domain.Secret

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        dependencies: %{secrets: %Dependencies{} = deps}
      }) do
    limit = bounded_limit(Map.get(input, :limit, 100))
    cursor = Map.get(input, :cursor)

    with :ok <- valid_cursor(cursor),
         {:ok, target_version} <- deps.cipher.current_version(),
         {:ok, secrets} <- deps.repository.list_for_rotation(target_version, cursor, limit + 1),
         {batch, remaining} = Enum.split(secrets, limit),
         {:ok, rotated} <- rotate_batch(batch, target_version, actor_id, deps) do
      {:ok,
       %{
         rotated: length(rotated),
         target_version: target_version,
         next_cursor: next_cursor(rotated, remaining),
         complete: remaining == []
       }}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp rotate_batch(secrets, target_version, actor_id, deps) do
    Enum.reduce_while(secrets, {:ok, []}, fn secret, {:ok, rotated} ->
      with {:ok, plaintext} <- deps.cipher.decrypt(Map.from_struct(secret), Secret.aad(secret)),
           {:ok, encrypted} <- deps.cipher.encrypt(plaintext, Secret.aad(secret)),
           true <- encrypted.key_version == target_version,
           updated = struct!(Secret, Map.merge(Map.from_struct(secret), encrypted)),
           :ok <-
             deps.repository.rotate(updated, secret.key_version, %{
               actor_id: actor_id,
               action: "secret.key_rotated",
               occurred_at: DateTime.truncate(deps.clock.now(), :microsecond)
             }) do
        {:cont, {:ok, [updated | rotated]}}
      else
        false -> {:halt, {:error, :current_key_changed_during_rotation}}
        {:error, reason} -> {:halt, {:error, {:secret_rotation_failed, secret.id, reason}}}
      end
    end)
    |> case do
      {:ok, rotated} -> {:ok, Enum.reverse(rotated)}
      error -> error
    end
  end

  defp next_cursor([], _remaining), do: nil
  defp next_cursor(_rotated, []), do: nil
  defp next_cursor(rotated, _remaining), do: List.last(rotated).id

  defp valid_cursor(nil), do: :ok
  defp valid_cursor(cursor) when is_binary(cursor), do: :ok
  defp valid_cursor(_cursor), do: {:error, {:invalid_rotation, :cursor}}

  defp bounded_limit(value) when is_integer(value) and value in 1..1_000, do: value
  defp bounded_limit(_value), do: 100
end
