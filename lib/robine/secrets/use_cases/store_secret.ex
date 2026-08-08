defmodule Robine.Secrets.UseCases.StoreSecret do
  @moduledoc "Validates, encrypts, and atomically audits a write-only secret."

  alias Robine.ExecutionContext
  alias Robine.Secrets.Contracts.SecretMetadata
  alias Robine.Secrets.Dependencies
  alias Robine.Secrets.Domain.Secret

  @name ~r/\A[A-Z_][A-Z0-9_]{0,127}\z/

  @spec call(map(), ExecutionContext.t()) :: {:ok, SecretMetadata.t()} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{id: actor_id, role: role},
        dependencies: %{secrets: %Dependencies{} = dependencies}
      })
      when role in [:administrator, :maintainer] do
    with {:ok, normalized} <- validate(input, role),
         id = dependencies.id_generator.generate(),
         inserted_at = DateTime.truncate(dependencies.clock.now(), :microsecond),
         aad_input = Map.merge(normalized, %{id: id}),
         {:ok, encrypted} <- dependencies.cipher.encrypt(normalized.value, Secret.aad(aad_input)),
         secret_fields = Map.delete(aad_input, :value),
         secret <-
           struct!(
             Secret,
             Map.merge(secret_fields, Map.merge(encrypted, %{inserted_at: inserted_at}))
           ),
         :ok <-
           dependencies.repository.upsert(secret, %{
             actor_id: actor_id,
             action: "secret.stored",
             occurred_at: inserted_at
           }) do
      {:ok,
       struct!(SecretMetadata, %{
         id: secret.id,
         name: secret.name,
         scope: secret.scope,
         repository_id: secret.repository_id,
         allowed_repository_ids: secret.allowed_repository_ids,
         inserted_at: secret.inserted_at
       })}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp validate(input, role) when is_map(input) do
    name = Map.get(input, :name)
    value = Map.get(input, :value)
    scope = Map.get(input, :scope, :repository)
    repository_id = Map.get(input, :repository_id)
    grants = Map.get(input, :allowed_repository_ids, [])

    cond do
      not (is_binary(name) and Regex.match?(@name, name)) ->
        {:error, {:invalid_secret, :name}}

      not (is_binary(value) and byte_size(value) >= 8) ->
        {:error, {:invalid_secret, :value_too_short}}

      scope == :repository and not is_binary(repository_id) ->
        {:error, {:invalid_secret, :repository_id}}

      scope == :instance and role != :administrator ->
        {:error, :forbidden}

      scope == :instance and (not is_list(grants) or not Enum.all?(grants, &is_binary/1)) ->
        {:error, {:invalid_secret, :allowed_repository_ids}}

      scope not in [:repository, :instance] ->
        {:error, {:invalid_secret, :scope}}

      true ->
        {:ok,
         %{
           name: name,
           value: value,
           scope: scope,
           repository_id: if(scope == :repository, do: repository_id),
           allowed_repository_ids: if(scope == :instance, do: Enum.uniq(grants), else: [])
         }}
    end
  end
end
