defmodule Robine.BuildInfo.UseCases.Get do
  @moduledoc "Returns the immutable compile-time build provenance for support presentation."

  alias Robine.BuildInfo.Contracts.Embedded

  @spec call(map()) :: map()
  def call(_input) do
    embedded = Embedded.current()
    release? = release_build?(embedded.commit_sha, embedded.built_at)

    embedded
    |> Map.put(
      :short_commit,
      String.slice(embedded.commit_sha, 0, 8)
    )
    |> Map.put(
      :display_ref,
      if(embedded.ref_name in [nil, ""], do: "local", else: embedded.ref_name)
    )
    |> Map.put(:release?, release?)
  end

  defp release_build?(commit_sha, built_at) do
    Regex.match?(~r/\A[0-9a-f]{40}\z/, commit_sha) and
      match?({:ok, _datetime, 0}, DateTime.from_iso8601(built_at))
  end
end
