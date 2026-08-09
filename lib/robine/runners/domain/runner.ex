defmodule Robine.Runners.Domain.Runner do
  @moduledoc "A machine identity authorized to request CI work."

  @enforce_keys [:id, :name, :admin_state, :inserted_at]
  defstruct [
    :id,
    :name,
    :admin_state,
    :protocol_version,
    :software_version,
    :capabilities,
    :labels,
    :last_authenticated_at,
    :last_seen_at,
    :revoked_at,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          admin_state: :enabled | :draining | :revoked,
          protocol_version: pos_integer() | nil,
          software_version: String.t() | nil,
          capabilities: map(),
          labels: [String.t()],
          last_authenticated_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_runner}
  def new(%{id: id, name: name, inserted_at: %DateTime{} = inserted_at})
      when is_binary(id) and is_binary(name) do
    normalized = String.trim(name)

    if normalized != "" and String.length(normalized) <= 80 do
      {:ok,
       %__MODULE__{
         id: id,
         name: normalized,
         admin_state: :enabled,
         capabilities: %{},
         labels: [],
         inserted_at: inserted_at,
         updated_at: inserted_at
       }}
    else
      {:error, :invalid_runner}
    end
  end

  def new(_attributes), do: {:error, :invalid_runner}

  @spec configure(t(), map(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def configure(%__MODULE__{admin_state: :revoked}, _changes, _now),
    do: {:error, :runner_revoked}

  def configure(%__MODULE__{} = runner, changes, %DateTime{} = now) when is_map(changes) do
    name = changes |> Map.get(:name, runner.name) |> normalize_name()
    labels = changes |> Map.get(:labels, runner.labels) |> normalize_labels()
    state = Map.get(changes, :admin_state, runner.admin_state)

    cond do
      name == :error ->
        {:error, :invalid_runner_name}

      match?({:error, _}, labels) ->
        labels

      state not in [:enabled, :draining] ->
        {:error, :invalid_runner_state}

      true ->
        {:ok,
         %{runner | name: name, labels: elem(labels, 1), admin_state: state, updated_at: now}}
    end
  end

  def configure(%__MODULE__{}, _changes, _now), do: {:error, :invalid_runner_configuration}

  defp normalize_name(name) when is_binary(name) do
    normalized = String.trim(name)
    if normalized != "" and String.length(normalized) <= 80, do: normalized, else: :error
  end

  defp normalize_name(_name), do: :error

  defp normalize_labels(labels) when is_list(labels) and length(labels) <= 32 do
    normalized = labels |> Enum.map(&normalize_label/1) |> Enum.uniq()

    if Enum.all?(normalized, &is_binary/1),
      do: {:ok, normalized},
      else: {:error, :invalid_runner_labels}
  end

  defp normalize_labels(_labels), do: {:error, :invalid_runner_labels}

  defp normalize_label(label) when is_binary(label) do
    normalized = String.trim(label)

    if Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/, normalized),
      do: normalized,
      else: :error
  end

  defp normalize_label(_label), do: :error
end
