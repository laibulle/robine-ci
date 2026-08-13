defmodule Mix.Tasks.Robine.Ci.Migrate do
  use Mix.Task

  @shortdoc "Runs Robine CI migrations for an embedding host"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(arguments) do
    {options, _, invalid} =
      OptionParser.parse(arguments, strict: [repo: :string, prefix: :string], aliases: [r: :repo])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    prefix = Keyword.get(options, :prefix, Robine.Runtime.Metadata.default_prefix())
    validate_prefix!(prefix)

    repo =
      arguments
      |> Mix.Ecto.parse_repo()
      |> case do
        [repo] -> repo
        [] -> Mix.raise("pass exactly one host repository with --repo MyApp.Repo")
        _repos -> Mix.raise("pass exactly one host repository")
      end

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, fn started_repo ->
        Ecto.Adapters.SQL.query!(started_repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"), [])

        Ecto.Migrator.run(
          started_repo,
          Robine.Runtime.Metadata.migrations_path(),
          :up,
          Robine.Runtime.Metadata.migrator_options(prefix: prefix)
        )
      end)

    Mix.shell().info("Robine CI migrations are current in PostgreSQL prefix #{prefix}")
  end

  defp validate_prefix!(prefix) do
    unless Regex.match?(~r/^[a-z][a-z0-9_]{0,62}$/, prefix) do
      Mix.raise("prefix must match [a-z][a-z0-9_]{0,62}")
    end
  end
end
