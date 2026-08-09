defmodule Robine.Transfers.UseCases.CreateSourceArchive do
  @moduledoc "Creates one bounded archive from already authorized source files."

  alias Robine.ExecutionContext
  alias Robine.Transfers.Dependencies

  def call(%{files: files}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{transfers: %Dependencies{} = deps}
      })
      when is_map(files) do
    deps.archive.create_source(files)
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
