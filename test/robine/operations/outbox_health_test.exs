defmodule Robine.Operations.OutboxHealthTest do
  use Robine.DataCase, async: false

  alias Robine.Adapters.Background.OutboxDeliveryWorker
  alias Robine.Operations
  alias Robine.Runtime.Dependencies
  alias Robine.Repo

  test "health exposes dead-letter outbox jobs without leaking event payloads" do
    context = Dependencies.context(%{id: "admin", role: :administrator}, "outbox-health")

    event_id = Ecto.UUID.generate()

    {:ok, job} =
      %{event_id: event_id}
      |> OutboxDeliveryWorker.new()
      |> Oban.insert()

    job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()

    assert {:ok, health} = Operations.health(%{}, context)
    assert health.checks.outbox.status == :error
    assert health.checks.outbox.dead_letters == 1
    refute health.checks.outbox.detail =~ event_id
  end
end
