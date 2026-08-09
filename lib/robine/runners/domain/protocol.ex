defmodule Robine.Runners.Domain.Protocol do
  @moduledoc "Version negotiation and bounded hello-document policy for runner sessions."

  @supported_versions [1]
  @max_capabilities 32

  @spec negotiate([term()], map(), String.t()) ::
          {:ok, %{version: pos_integer(), capabilities: map(), software_version: String.t()}}
          | {:error, term()}
  def negotiate(versions, capabilities, software_version)
      when is_list(versions) and is_map(capabilities) and is_binary(software_version) do
    version =
      versions
      |> Enum.filter(&(&1 in @supported_versions))
      |> Enum.max(fn -> nil end)

    cond do
      is_nil(version) ->
        {:error, :incompatible_protocol}

      map_size(capabilities) > @max_capabilities ->
        {:error, :invalid_capabilities}

      byte_size(software_version) not in 1..64 ->
        {:error, :invalid_software_version}

      not valid_capabilities?(capabilities) ->
        {:error, :invalid_capabilities}

      true ->
        {:ok, %{version: version, capabilities: capabilities, software_version: software_version}}
    end
  end

  def negotiate(_versions, _capabilities, _software_version), do: {:error, :invalid_hello}

  defp valid_capabilities?(capabilities) do
    Enum.all?(capabilities, fn
      {key, value} when is_binary(key) and byte_size(key) in 1..63 ->
        valid_capability_value?(value)

      _entry ->
        false
    end)
  end

  defp valid_capability_value?(value) when is_boolean(value), do: true
  defp valid_capability_value?(value) when is_integer(value), do: value in 0..1_000_000
  defp valid_capability_value?(value) when is_binary(value), do: byte_size(value) <= 128
  defp valid_capability_value?(_value), do: false
end
