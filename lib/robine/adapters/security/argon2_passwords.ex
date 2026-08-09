defmodule Robine.Adapters.Security.Argon2Passwords do
  @moduledoc false
  @behaviour Robine.Identities.Ports.Passwords
  @impl true
  def hash(password), do: Argon2.hash_pwd_salt(password)
  @impl true
  def verify(password, hash), do: Argon2.verify_pass(password, hash)
  @impl true
  def dummy_verify, do: Argon2.no_user_verify()
end
