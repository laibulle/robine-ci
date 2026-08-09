defmodule Robine.Repositories.Domain.GitHubPermissionPolicy do
  @moduledoc "Evaluates the least-privilege GitHub App installation contract."

  @required %{"metadata" => "read", "contents" => "read", "checks" => "write"}

  @spec evaluate(map()) :: map()
  def evaluate(permissions) when is_map(permissions) do
    normalized = Map.new(permissions, fn {name, level} -> {to_string(name), to_string(level)} end)

    missing =
      for {name, required} <- @required,
          actual = Map.get(normalized, name, "none"),
          not sufficient?(actual, required) do
        %{
          permission: name,
          required: required,
          actual: actual,
          corrective_action:
            "Update the GitHub App repository permission '#{name}' to '#{required}', then approve the installation permission update."
        }
      end
      |> Enum.sort_by(& &1.permission)

    %{
      status: if(missing == [], do: :ok, else: :degraded),
      permissions: normalized,
      missing: missing
    }
  end

  defp sufficient?("write", required), do: required in ["read", "write"]
  defp sufficient?("read", "read"), do: true
  defp sufficient?(_actual, _required), do: false
end
