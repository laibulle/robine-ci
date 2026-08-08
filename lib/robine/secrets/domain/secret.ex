defmodule Robine.Secrets.Domain.Secret do
  @moduledoc "Encrypted secret metadata and scope policy."

  @enforce_keys [:id, :name, :scope, :ciphertext, :nonce, :tag, :key_version, :inserted_at]
  defstruct [
    :id,
    :name,
    :scope,
    :repository_id,
    :allowed_repository_ids,
    :ciphertext,
    :nonce,
    :tag,
    :key_version,
    :inserted_at
  ]

  @type scope :: :repository | :instance
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          scope: scope(),
          repository_id: String.t() | nil,
          allowed_repository_ids: [String.t()],
          ciphertext: binary(),
          nonce: binary(),
          tag: binary(),
          key_version: pos_integer(),
          inserted_at: DateTime.t()
        }

  @spec authorized_for?(t(), String.t()) :: boolean()
  def authorized_for?(%__MODULE__{scope: :repository, repository_id: id}, id), do: true

  def authorized_for?(%__MODULE__{scope: :instance, allowed_repository_ids: ids}, repository_id),
    do: repository_id in ids

  def authorized_for?(%__MODULE__{}, _repository_id), do: false

  @spec aad(t() | map()) :: binary()
  def aad(secret) do
    :erlang.term_to_binary({
      Map.fetch!(secret, :id),
      Map.fetch!(secret, :name),
      Map.fetch!(secret, :scope),
      Map.get(secret, :repository_id),
      Enum.sort(Map.get(secret, :allowed_repository_ids, []))
    })
  end
end
