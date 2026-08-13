defmodule Robine.Runtime.Metadata do
  @moduledoc "Public package and database metadata for embedding applications."

  @spec version() :: String.t()
  def version, do: :robine |> Application.spec(:vsn) |> to_string()

  @spec migrations_path() :: String.t()
  def migrations_path,
    do: :robine |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")

  @spec default_prefix() :: String.t()
  def default_prefix, do: "robine_ci"

  @doc "Options suitable for `Ecto.Migrator.run/4` in an embedding host."
  @spec migrator_options(keyword()) :: keyword()
  def migrator_options(options \\ []) do
    options
    |> Keyword.put_new(:all, true)
    |> Keyword.put_new(:prefix, default_prefix())
  end
end
