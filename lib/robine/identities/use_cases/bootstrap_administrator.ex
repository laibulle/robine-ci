defmodule Robine.Identities.UseCases.BootstrapAdministrator do
  @moduledoc "Creates the first administrator using an expiring out-of-band token."
  alias Robine.ExecutionContext
  alias Robine.Identities.Dependencies

  def call(%{token: token, email: email, password: password}, %ExecutionContext{
        dependencies: %{identities: %Dependencies{} = deps}
      })
      when is_binary(token) and is_binary(email) and is_binary(password) do
    now = deps.clock.now()

    with :ok <- valid_token(token, deps.bootstrap_token_hash),
         :ok <- unexpired(now, deps.bootstrap_expires_at),
         :ok <- valid_email(email),
         :ok <- valid_password(password),
         password_hash = deps.passwords.hash(password),
         {:ok, user} <-
           deps.repository.bootstrap_user(
             %{
               id: deps.id_generator.generate(),
               email: String.downcase(email),
               role: :administrator,
               disabled: false,
               inserted_at: now
             },
             %{id: deps.id_generator.generate(), password_hash: password_hash, inserted_at: now}
           ) do
      {:ok, Map.take(user, [:id, :email, :role])}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :invalid_bootstrap_request}

  defp valid_token(token, expected) do
    actual = :crypto.hash(:sha256, token)

    if byte_size(expected) == byte_size(actual) and :crypto.hash_equals(actual, expected),
      do: :ok,
      else: {:error, :invalid_bootstrap_token}
  end

  defp unexpired(now, expires_at),
    do: if(DateTime.before?(now, expires_at), do: :ok, else: {:error, :bootstrap_token_expired})

  defp valid_email(email),
    do: if(email =~ ~r/^[^\s@]+@[^\s@]+$/, do: :ok, else: {:error, :invalid_email})

  defp valid_password(password),
    do: if(String.length(password) >= 12, do: :ok, else: {:error, :weak_password})
end
