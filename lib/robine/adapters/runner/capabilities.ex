defmodule Robine.Adapters.Runner.Capabilities do
  @moduledoc "Normalizes host facts and selects the remote runner execution mode."

  @spec detect({atom(), atom()}, String.t(), boolean()) :: map()
  def detect(
        os_type \\ :os.type(),
        architecture \\ to_string(:erlang.system_info(:system_architecture)),
        deployments? \\ false
      ) do
    os = normalize_os(os_type)
    executor = if os == "macos", do: "native", else: "docker"

    %{
      "os" => os,
      "architecture" => normalize_architecture(architecture),
      "docker" => executor == "docker",
      "native" => executor == "native",
      "executor" => executor,
      "deployments" => deployments?,
      "concurrency" => 1
    }
  end

  @spec execution_mode(map()) :: :docker | :native | {:error, :invalid_executor}
  def execution_mode(%{"executor" => "native"}), do: :native
  def execution_mode(%{"executor" => "docker"}), do: :docker
  def execution_mode(%{"executor" => _other}), do: {:error, :invalid_executor}
  def execution_mode(_legacy_config), do: :docker

  defp normalize_os({:unix, :darwin}), do: "macos"
  defp normalize_os({:unix, :linux}), do: "linux"
  defp normalize_os({family, name}), do: "#{family}-#{name}"

  defp normalize_architecture(value) do
    cond do
      String.starts_with?(value, "aarch64") or String.starts_with?(value, "arm64") -> "arm64"
      String.starts_with?(value, "x86_64") or String.starts_with?(value, "amd64") -> "amd64"
      true -> value |> String.split("-", parts: 2) |> hd()
    end
  end
end
