defmodule Robine.Repo do
  use Ecto.Repo,
    otp_app: :robine,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def default_options(_operation) do
    case Application.get_env(:robine, :database_prefix) do
      prefix when is_binary(prefix) and prefix != "" -> [prefix: prefix]
      _default -> []
    end
  end
end
