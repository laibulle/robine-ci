defmodule Robine.Secrets.Domain.ValuePolicy do
  @moduledoc "Bounds secret values and derives the representations masked from logs."

  @minimum_bytes 8
  @maximum_bytes 65_536

  @spec minimum_bytes() :: pos_integer()
  def minimum_bytes, do: @minimum_bytes

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec validate(term()) :: :ok | {:error, :not_binary | :secret_too_short | :secret_too_large}
  def validate(value) when not is_binary(value), do: {:error, :not_binary}
  def validate(value) when byte_size(value) < @minimum_bytes, do: {:error, :secret_too_short}
  def validate(value) when byte_size(value) > @maximum_bytes, do: {:error, :secret_too_large}
  def validate(_value), do: :ok

  @doc "Returns every exact representation covered by the redaction contract."
  @spec variants(binary()) :: [binary()]
  def variants(value) when is_binary(value) do
    [
      value,
      Base.encode64(value),
      Base.encode64(value, padding: false),
      Base.url_encode64(value),
      Base.url_encode64(value, padding: false),
      percent_encode(value)
    ]
    |> Enum.uniq()
  end

  defp percent_encode(value) do
    for <<byte <- value>>, into: <<>> do
      <<?%, Base.encode16(<<byte>>, case: :upper)::binary>>
    end
  end
end
