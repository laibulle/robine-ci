defmodule Robine.Adapters.Storage.BackendGuard do
  @moduledoc false

  use GenServer
  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Artifact,
    CacheEntry,
    StorageBackendState
  }

  alias Robine.Adapters.Storage.{LocalBlobStore, S3BlobStore}
  alias Robine.Repo

  @state_id "primary"

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  def verify, do: Repo.transaction(&verify_in_transaction/0) |> unwrap_transaction()

  @doc false
  def transition_ack(previous_digest, next_digest) do
    :crypto.hash(:sha256, "#{previous_digest}->#{next_digest}")
    |> Base.encode16(case: :lower)
  end

  @impl true
  def init(_options) do
    case verify() do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp verify_in_transaction do
    current = current_backend()

    state =
      Repo.one(from row in StorageBackendState, where: row.id == @state_id, lock: "FOR UPDATE")

    case state do
      nil -> initialize_state(current)
      %StorageBackendState{} = stored -> reconcile_state(stored, current)
    end
  end

  defp initialize_state(current) do
    if retained_metadata?() and current.backend != "local" do
      require_ack!("unrecorded", current.digest)
    end

    %StorageBackendState{}
    |> StorageBackendState.changeset(%{
      id: @state_id,
      backend: current.backend,
      namespace_digest: current.digest,
      acknowledged_at: acknowledgement_time("unrecorded", current.digest)
    })
    |> Repo.insert!()

    :ok
  end

  defp reconcile_state(stored, current) do
    if stored.backend == current.backend and stored.namespace_digest == current.digest do
      :ok
    else
      acknowledged_at =
        if retained_metadata?() do
          require_ack!(stored.namespace_digest, current.digest)
          DateTime.utc_now()
        end

      stored
      |> StorageBackendState.changeset(%{
        backend: current.backend,
        namespace_digest: current.digest,
        acknowledged_at: acknowledged_at
      })
      |> Repo.update!()

      :ok
    end
  end

  defp require_ack!(previous_digest, next_digest) do
    expected = transition_ack(previous_digest, next_digest)

    unless Application.get_env(:robine, :storage_backend_migration_ack) == expected do
      Repo.rollback({:storage_backend_migration_ack_required, expected})
    end
  end

  defp acknowledgement_time(previous_digest, next_digest) do
    expected = transition_ack(previous_digest, next_digest)

    if Application.get_env(:robine, :storage_backend_migration_ack) == expected,
      do: DateTime.utc_now()
  end

  defp retained_metadata? do
    Repo.exists?(from artifact in Artifact, select: 1) or
      Repo.exists?(from cache in CacheEntry, select: 1)
  end

  defp current_backend do
    case Application.fetch_env!(:robine, :blob_store_adapter) do
      LocalBlobStore ->
        locator = Path.expand(Application.fetch_env!(:robine, :storage_root))
        %{backend: "local", digest: digest("local:#{locator}")}

      S3BlobStore ->
        options = Application.fetch_env!(:robine, :s3_blob_store)
        endpoint = Keyword.fetch!(options, :endpoint) |> String.trim_trailing("/")
        bucket = Keyword.fetch!(options, :bucket)
        prefix = Keyword.get(options, :prefix, "") |> String.trim("/")
        %{backend: "s3", digest: digest("s3:#{endpoint}/#{bucket}/#{prefix}")}
    end
  end

  defp digest(locator), do: :crypto.hash(:sha256, locator) |> Base.encode16(case: :lower)
  defp unwrap_transaction({:ok, :ok}), do: :ok
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
