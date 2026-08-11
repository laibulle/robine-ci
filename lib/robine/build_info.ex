defmodule Robine.BuildInfo do
  @moduledoc "Public API for the build provenance embedded into this Robine release."

  alias Robine.BuildInfo.UseCases

  @spec current(map()) :: map()
  defdelegate current(input), to: UseCases.Get, as: :call
end
