defmodule Robine.Adapters.Runner.BundledBootstrap do
  @moduledoc "Creates the private one-use handoff used to enroll the bundled Go runner."

  use GenServer
  import Bitwise
  require Logger

  alias Robine.Runtime.Dependencies
  alias Robine.Runners

  @retry_ms 5_000
  @refresh_after_seconds 10 * 60

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    config = Keyword.get(options, :config, Application.fetch_env!(:robine, :bundled_runner))
    directory = Keyword.fetch!(config, :bootstrap_directory)

    state = %{
      directory: directory,
      token_path: Path.join(directory, "enrollment-token"),
      marker_path: Path.join(directory, "configured"),
      context:
        Keyword.get_lazy(options, :context, fn ->
          Dependencies.system_context(
            Robine.ExecutionContext.standalone_tenant(),
            "system:bundled-runner",
            "bundled-runner:bootstrap"
          )
        end)
    }

    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    case reconcile(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("bundled runner bootstrap unavailable: #{failure_class(reason)}")
    end

    Process.send_after(self(), :reconcile, @retry_ms)
    {:noreply, state}
  end

  defp reconcile(state) do
    with :ok <- File.mkdir_p(state.directory),
         :ok <- File.chmod(state.directory, 0o700) do
      cond do
        File.regular?(state.marker_path) ->
          remove_token(state.token_path)

        fresh_token?(state.token_path) ->
          :ok

        true ->
          create_token(state)
      end
    end
  end

  defp create_token(state) do
    with {:ok, enrollment} <- Runners.create_enrollment_token(%{}, state.context),
         :ok <- write_private(state.token_path, enrollment.token) do
      :ok
    end
  end

  defp fresh_token?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mode: mode, mtime: modified}}
      when band(mode, 0o077) == 0 ->
        System.os_time(:second) - modified < @refresh_after_seconds

      _other ->
        false
    end
  end

  defp write_private(path, content) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  defp remove_token(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp failure_class(reason) when reason in [:eacces, :eexist, :enospc, :enotdir, :erofs],
    do: reason

  defp failure_class(_reason), do: :unavailable
end
