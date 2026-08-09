defmodule Robine.Adapters.Identity.AssentOIDCTest do
  use ExUnit.Case, async: true

  alias Robine.Adapters.Identity.AssentOIDC

  @client_secret "01234567890123456789012345678901"

  defmodule FakeHTTP do
    @behaviour Assent.HTTPAdapter

    @impl true
    def request(method, url, body, headers, _options) do
      send(self(), {:oidc_http_request, method, url, body, headers})

      {:ok,
       %Assent.HTTPAdapter.HTTPResponse{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "access_token" => "access-token",
           "token_type" => "Bearer",
           "id_token" => Process.get({__MODULE__, :id_token}) || raise("missing test ID token")
         }
       }}
    end
  end

  test "authorization enables unpredictable state, nonce, and S256 PKCE" do
    assert {:ok, %{url: url, session_params: session}} =
             AssentOIDC.authorize_url(Keyword.delete(config(), :session_params))

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert byte_size(session.state) >= 32
    assert byte_size(session.nonce) >= 32
    assert byte_size(session.code_verifier) >= 64
    assert query["state"] == session.state
    assert query["nonce"] == session.nonce
    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["code_challenge"])
    refute url =~ session.code_verifier
  end

  test "callback validates state and sends the PKCE verifier" do
    Process.put({FakeHTTP, :id_token}, signed_token(%{}))

    assert {:ok, %{claims: claims}} =
             AssentOIDC.callback(config(), %{"code" => "code", "state" => "state"})

    assert claims["sub"] == "subject-1"
    assert claims["email"] == "dev@example.com"

    assert_receive {:oidc_http_request, :post, "https://id.example/token", body, _headers}
    assert URI.decode_query(body)["code_verifier"] == "verifier"

    assert {:error, {:oidc, %Assent.CallbackCSRFError{}}} =
             AssentOIDC.callback(config(), %{"code" => "code", "state" => "wrong"})
  end

  test "callback rejects issuer, audience, nonce, and signature alterations" do
    for claims <- [
          %{"iss" => "https://attacker.example"},
          %{"aud" => "other-client"},
          %{"nonce" => "other-nonce"}
        ] do
      Process.put({FakeHTTP, :id_token}, signed_token(claims))

      assert {:error, {:oidc, _reason}} =
               AssentOIDC.callback(config(), %{"code" => "code", "state" => "state"})
    end

    [header, payload, signature] = String.split(signed_token(%{}), ".")
    {:ok, <<first, rest::binary>>} = Base.url_decode64(signature, padding: false)

    changed_signature =
      Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

    tampered = header <> "." <> payload <> "." <> changed_signature
    Process.put({FakeHTTP, :id_token}, tampered)

    assert {:error, {:oidc, _reason}} =
             AssentOIDC.callback(config(), %{"code" => "code", "state" => "state"})
  end

  defp config do
    [
      base_url: "https://id.example",
      client_id: "client",
      client_secret: @client_secret,
      redirect_uri: "https://robine.example/auth/oidc/callback",
      id_token_signed_response_alg: "HS256",
      trusted_audiences: ["client"],
      session_params: %{state: "state", nonce: "nonce", code_verifier: "verifier"},
      openid_configuration: %{
        "issuer" => "https://id.example",
        "authorization_endpoint" => "https://id.example/authorize",
        "token_endpoint" => "https://id.example/token",
        "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
      },
      http_adapter: FakeHTTP
    ]
  end

  defp signed_token(overrides) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://id.example",
          "sub" => "subject-1",
          "aud" => "client",
          "exp" => now + 300,
          "iat" => now,
          "nonce" => "nonce",
          "email" => "dev@example.com",
          "email_verified" => true
        },
        overrides
      )

    {:ok, token} = Assent.JWTAdapter.sign(claims, "HS256", @client_secret)
    token
  end
end
