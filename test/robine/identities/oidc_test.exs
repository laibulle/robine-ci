defmodule Robine.Identities.OIDCTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Persistence.Postgres.Schemas.{OIDCIdentity, Session}
  alias Robine.Identities
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  defmodule FakeOIDC do
    @behaviour Robine.Identities.Ports.OIDC
    @impl true
    def authorize_url(config) do
      send(self(), {:authorize, config})

      {:ok,
       %{
         url: "https://id.example/authorize",
         session_params: %{state: "state", nonce: "nonce", code_verifier: "verifier"}
       }}
    end

    @impl true
    def callback(config, params) do
      send(self(), {:callback, config, params})
      {:ok, %{claims: params.claims}}
    end
  end

  test "starts with protocol state and provisions only by stable issuer and subject" do
    context = oidc_context()

    assert {:ok, %{url: "https://id.example/authorize", session_params: %{state: "state"}}} =
             Identities.start_oidc(%{}, context)

    assert_receive {:authorize, config}
    assert config[:base_url] == "https://id.example"

    claims = %{
      "iss" => "https://id.example",
      "sub" => "subject-1",
      "email" => "dev@example.com",
      "email_verified" => true
    }

    assert {:ok, %{user: %{email: "dev@example.com", role: :viewer}}} =
             Identities.complete_oidc(
               %{params: %{claims: claims}, session_params: %{state: "state"}},
               context
             )

    assert Repo.aggregate(OIDCIdentity, :count) == 1
    assert Repo.aggregate(Session, :count) == 1

    conflicting_subject = %{claims | "sub" => "subject-2"}

    assert {:error, :oidc_email_collision} =
             Identities.complete_oidc(
               %{params: %{claims: conflicting_subject}, session_params: %{}},
               context
             )

    changed_email = %{claims | "email" => "renamed@example.com"}

    assert {:ok, %{user: %{email: "dev@example.com"}}} =
             Identities.complete_oidc(
               %{params: %{claims: changed_email}, session_params: %{state: "next"}},
               context
             )

    assert Repo.aggregate(OIDCIdentity, :count) == 1
  end

  test "links the first verified OIDC subject to an active local recovery account" do
    context = oidc_context()

    assert {:ok, _admin} =
             Identities.bootstrap_administrator(
               %{
                 token: "test-bootstrap-token",
                 email: "admin@example.com",
                 password: "a secure password"
               },
               context
             )

    claims = %{
      "iss" => "https://id.example",
      "sub" => "admin-subject",
      "email" => "admin@example.com",
      "email_verified" => true
    }

    assert {:ok, %{user: %{email: "admin@example.com", role: :administrator}}} =
             Identities.complete_oidc(
               %{params: %{claims: claims}, session_params: %{}},
               context
             )

    assert Repo.aggregate(OIDCIdentity, :count) == 1
    assert Repo.aggregate(Session, :count) == 1

    second_subject = %{claims | "sub" => "different-subject"}

    assert {:error, :oidc_email_collision} =
             Identities.complete_oidc(
               %{params: %{claims: second_subject}, session_params: %{}},
               context
             )

    assert Repo.aggregate(OIDCIdentity, :count) == 1
  end

  test "rejects unverified email" do
    context = oidc_context()

    unverified = %{
      "iss" => "https://id.example",
      "sub" => "subject",
      "email" => "other@example.com",
      "email_verified" => false
    }

    assert {:error, :unverified_oidc_identity} =
             Identities.complete_oidc(
               %{params: %{claims: unverified}, session_params: %{}},
               context
             )
  end

  defp oidc_context do
    context = Dependencies.context(%{id: "anonymous", role: :viewer}, "oidc-test")
    dependencies = context.dependencies.identities

    configured = %{
      dependencies
      | oidc: FakeOIDC,
        oidc_config: [
          base_url: "https://id.example",
          client_id: "client",
          redirect_uri: "http://localhost/auth/oidc/callback"
        ]
    }

    %{context | dependencies: %{context.dependencies | identities: configured}}
  end
end
