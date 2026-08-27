defmodule Robine.Publications.Domain.RepositoryPolicy do
  @moduledoc "Explicit repository declassification policy for public releases."

  @enforce_keys [:id, :repository_id, :enabled, :public_slug, :inserted_at, :updated_at]
  defstruct [:id, :repository_id, :enabled, :public_slug, :inserted_at, :updated_at]

  @slug ~r/\A[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?\z/

  @type t :: %__MODULE__{
          id: String.t(),
          repository_id: String.t(),
          enabled: boolean(),
          public_slug: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_publication_policy, atom()}}
  def new(attributes) when is_map(attributes) do
    policy = struct(__MODULE__, attributes)

    cond do
      not valid_id?(policy.id) ->
        {:error, {:invalid_publication_policy, :id}}

      not valid_id?(policy.repository_id) ->
        {:error, {:invalid_publication_policy, :repository_id}}

      not is_boolean(policy.enabled) ->
        {:error, {:invalid_publication_policy, :enabled}}

      not valid_slug?(policy.public_slug) ->
        {:error, {:invalid_publication_policy, :public_slug}}

      not valid_time?(policy.inserted_at) ->
        {:error, {:invalid_publication_policy, :inserted_at}}

      not valid_time?(policy.updated_at) ->
        {:error, {:invalid_publication_policy, :updated_at}}

      true ->
        {:ok, policy}
    end
  end

  def new(_attributes), do: {:error, {:invalid_publication_policy, :shape}}

  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(slug), do: is_binary(slug) and Regex.match?(@slug, slug)

  defp valid_id?(value), do: is_binary(value) and value != ""
  defp valid_time?(%DateTime{}), do: true
  defp valid_time?(_value), do: false
end
