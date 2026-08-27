defmodule Robine.Publications.Domain.RepositoryPolicyTest do
  use ExUnit.Case, async: true
  alias Robine.Publications.Domain.RepositoryPolicy

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "accepts an explicit bounded public slug" do
    assert {:ok, policy} =
             RepositoryPolicy.new(%{
               id: "policy-1",
               repository_id: "repository-1",
               enabled: true,
               public_slug: "robine-cli",
               inserted_at: @now,
               updated_at: @now
             })

    assert policy.enabled
    assert policy.public_slug == "robine-cli"
  end

  test "rejects private names, paths, uppercase, and malformed slugs" do
    for slug <- ["Acme/private", "../private", "private_repo", "-private", "private-"] do
      assert {:error, {:invalid_publication_policy, :public_slug}} =
               RepositoryPolicy.new(%{
                 id: "policy-1",
                 repository_id: "repository-1",
                 enabled: true,
                 public_slug: slug,
                 inserted_at: @now,
                 updated_at: @now
               })
    end
  end
end
