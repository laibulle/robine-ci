defmodule Robine.Adapters.System.DiskAdmission do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.Admission

  @impl true
  def check do
    policy = Application.fetch_env!(:robine, :runner_admission)
    root = Application.fetch_env!(:robine, :storage_root)

    with :ok <- File.mkdir_p(root),
         {output, 0} <- System.cmd("df", ["-Pk", root], stderr_to_stdout: true),
         {:ok, capacity} <- parse_df(output) do
      if capacity.available_bytes >= Keyword.fetch!(policy, :min_free_bytes) and
           capacity.used_percent <= Keyword.fetch!(policy, :max_used_percent),
         do: :ok,
         else: {:error, :disk_pressure}
    else
      _ -> {:error, :disk_pressure}
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
