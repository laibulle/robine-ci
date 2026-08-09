defmodule Robine.Identities.UseCases.AuthenticateLocal do
  @moduledoc "Authenticates a local user and issues a revocable opaque session."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(%{email: email, password: password}, %ExecutionContext{
        dependencies: %{identities: %Dependencies{} = deps}
      })
      when is_binary(email) and is_binary(password) do
    case deps.repository.get_local_user(String.downcase(email)) do
      {:ok, %{disabled: false} = user} ->
        verify_and_issue(user, password, deps)

      _ ->
        (deps.passwords.dummy_verify() && {:error, :invalid_credentials}) ||
          {:error, :invalid_credentials}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_credentials}

  defp verify_and_issue(user, password, deps) do
    if deps.passwords.verify(password, user.password_hash) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      now = deps.clock.now()
      expires_at = DateTime.add(now, 86_400 * 7, :second)
      digest = :crypto.hash(:sha256, token)

      with :ok <-
             deps.repository.create_session(%{
               id: deps.id_generator.generate(),
               user_id: user.id,
               token_digest: digest,
               expires_at: expires_at,
               inserted_at: now
             }) do
        {:ok, %{token: token, expires_at: expires_at, user: Map.take(user, [:id, :email, :role])}}
      end
    else
      {:error, :invalid_credentials}
    end
  end
end
