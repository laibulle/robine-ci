defmodule Robine.Repo do
  use Ecto.Repo,
    otp_app: :robine,
    adapter: Ecto.Adapters.Postgres
end
