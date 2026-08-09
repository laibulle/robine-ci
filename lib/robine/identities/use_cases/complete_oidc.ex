defmodule Robine.Identities.UseCases.CompleteOIDC do
  @moduledoc "Validates an OIDC callback and issues a local revocable session."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(%{params: params, session_params: session_params}, %ExecutionContext{
        dependencies: %{identities: %Dependencies{oidc_config: config} = deps}
      })
      when is_map(params) and is_map(session_params) and not is_nil(config) do
    with {:ok, %{claims: claims}} <-
           deps.oidc.callback(Keyword.put(config, :session_params, session_params), params),
         {:ok, identity} <- identity(claims, config),
         {:ok, user} <-
           deps.repository.find_or_provision_oidc_user(identity, %{
             id: deps.id_generator.generate(),
             role: :viewer,
             inserted_at: deps.clock.now()
           }),
         {:ok, session} <- issue_session(user, deps) do
      {:ok, session}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_oidc_callback}

  defp identity(%{"sub" => subject} = claims, config) when is_binary(subject) and subject != "" do
    issuer = claims["iss"] || Keyword.fetch!(config, :base_url)
    email = claims["email"]

    if is_binary(issuer) and is_binary(email) and claims["email_verified"] == true,
      do: {:ok, %{issuer: issuer, subject: subject, email: String.downcase(email)}},
      else: {:error, :unverified_oidc_identity}
  end

  defp identity(_claims, _config), do: {:error, :invalid_oidc_subject}

  defp issue_session(user, deps) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = deps.clock.now()
    expires_at = DateTime.add(now, 86_400 * 7, :second)

    with :ok <-
           deps.repository.create_session(%{
             id: deps.id_generator.generate(),
             user_id: user.id,
             token_digest: :crypto.hash(:sha256, token),
             expires_at: expires_at,
             inserted_at: now
           }) do
      {:ok, %{token: token, expires_at: expires_at, user: Map.take(user, [:id, :email, :role])}}
    end
  end
end
