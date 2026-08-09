defmodule Robine.Runtime.Release do
  @moduledoc "Production release operations invoked through `bin/robine eval`."

  @app :robine

  @spec migrate() :: :ok
  def migrate do
    load_application()

    for repository <- repositories() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repository, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp repositories, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_application do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end
end
