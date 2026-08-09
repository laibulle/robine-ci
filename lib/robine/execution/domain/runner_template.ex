defmodule Robine.Execution.Domain.RunnerTemplate do
  @moduledoc "Resolves allowlisted runner-platform variables in execution metadata."

  @tokens %{
    "${{ runner.os }}" => :os,
    "${{ runner.arch }}" => :arch
  }

  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :unsupported_runner_template}
  def resolve(template) when is_binary(template) do
    values = platform()

    resolved =
      Enum.reduce(@tokens, template, fn {token, key}, value ->
        String.replace(value, token, Map.fetch!(values, key))
      end)

    if String.contains?(resolved, "${{"),
      do: {:error, :unsupported_runner_template},
      else: {:ok, resolved}
  end

  def resolve(_template), do: {:error, :unsupported_runner_template}

  @spec platform() :: %{os: String.t(), arch: String.t()}
  def platform do
    %{os: os(), arch: architecture()}
  end

  defp os do
    case :os.type() do
      {:unix, name} -> to_string(name)
      {:win32, _name} -> "windows"
    end
  end

  defp architecture do
    :erlang.system_info(:system_architecture)
    |> to_string()
    |> String.split("-")
    |> hd()
    |> normalize_architecture()
  end

  defp normalize_architecture("x86_64"), do: "amd64"
  defp normalize_architecture("aarch64"), do: "arm64"
  defp normalize_architecture("arm64"), do: "arm64"
  defp normalize_architecture(value), do: String.replace(value, ~r/[^a-zA-Z0-9_]/, "-")
end
