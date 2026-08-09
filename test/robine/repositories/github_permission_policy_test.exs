defmodule Robine.Repositories.GitHubPermissionPolicyTest do
  use ExUnit.Case, async: true

  alias Robine.Repositories.Domain.GitHubPermissionPolicy

  test "accepts the exact least-privilege installation permission set" do
    assert %{status: :ok, missing: []} =
             GitHubPermissionPolicy.evaluate(%{
               "metadata" => "read",
               "contents" => "read",
               "checks" => "write"
             })
  end

  test "reports every missing permission with an exact corrective action" do
    assert %{status: :degraded, missing: missing} =
             GitHubPermissionPolicy.evaluate(%{
               "metadata" => "read",
               "contents" => "none",
               "checks" => "read"
             })

    assert Enum.map(missing, & &1.permission) == ["checks", "contents"]
    assert Enum.all?(missing, &(&1.corrective_action =~ "approve the installation"))
    assert Enum.find(missing, &(&1.permission == "checks")).required == "write"
  end
end
