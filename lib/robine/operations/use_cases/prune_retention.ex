defmodule Robine.Operations.UseCases.PruneRetention do
  @moduledoc "Applies configured retention and drains eligible garbage."
  alias Robine.ExecutionContext
  alias Robine.Operations.Dependencies

  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{operations: %Dependencies{} = deps}
      }) do
    deps.retention.prune(
      Map.get(input, :now, DateTime.utc_now()),
      Application.fetch_env!(:robine, :retention),
      deps.blob_store
    )
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
