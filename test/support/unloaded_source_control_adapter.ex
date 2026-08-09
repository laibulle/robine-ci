defmodule Robine.Test.UnloadedSourceControlAdapter do
  @moduledoc false

  def available_repositories, do: {:ok, [%{full_name: "acme/widget"}]}
end
