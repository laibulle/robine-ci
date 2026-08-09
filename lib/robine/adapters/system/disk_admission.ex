defmodule Robine.Adapters.System.DiskAdmission do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.Admission

  @impl true
  def check do
    policy = Application.fetch_env!(:robine, :runner_admission)
    configured_max = Keyword.fetch!(policy, :max_used_percent)

    max_used_percent =
      if Application.get_env(:robine, :dev_routes, false),
        do: max(configured_max, 98),
        else: configured_max

    with {:ok, capacity} <- capacity() do
      if capacity.available_bytes >= Keyword.fetch!(policy, :min_free_bytes) and
           capacity.used_percent <= max_used_percent,
         do: :ok,
         else: {:error, :disk_pressure}
    else
      _ -> {:error, :disk_pressure}
    end
  rescue
    _error -> {:error, :disk_pressure}
  end

  @spec measure() :: :ok
  def measure do
    case capacity() do
      {:ok, capacity} ->
        :telemetry.execute(
          [:robine, :storage, :pressure],
          Map.put(capacity, :count, 1),
          %{status: :ok}
        )

      {:error, _reason} ->
        :telemetry.execute(
          [:robine, :storage, :pressure],
          %{available_bytes: 0, used_percent: 100, count: 1},
          %{status: :error}
        )
    end

    :ok
  end

  defp capacity do
    root = Application.fetch_env!(:robine, :storage_root)

    with :ok <- File.mkdir_p(root),
         {output, 0} <- System.cmd("df", ["-Pk", root], stderr_to_stdout: true),
         {:ok, capacity} <- parse_df(output) do
      {:ok, capacity}
    else
      _reason -> {:error, :disk_pressure}
    end
  rescue
    _error -> {:error, :disk_pressure}
  end

  @doc false
  def parse_df(output) when is_binary(output) do
    fields =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> String.split()

    with [_, _blocks, _used, available, percent | _mount] <- fields,
         {available_kib, ""} <- Integer.parse(available),
         {used_percent, "%"} <- Integer.parse(percent) do
      {:ok, %{available_bytes: available_kib * 1_024, used_percent: used_percent}}
    else
      _ -> {:error, :invalid_df_output}
    end
  end
end
