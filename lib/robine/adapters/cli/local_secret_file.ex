defmodule Robine.Adapters.CLI.LocalSecretFile do
  @moduledoc false

  alias Robine.Secrets

  @name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @maximum_file_bytes 1_048_576

  @spec load(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path, working_directory) do
    expanded = Path.expand(path, working_directory)

    with {:ok, repository_root} <- repository_root(working_directory),
         :ok <- below_root(expanded, repository_root),
         :ok <- regular_file(expanded),
         :ok <- ignored_by_git(expanded, repository_root),
         {:ok, %File.Stat{size: size}} <- File.stat(expanded),
         true <- size <= @maximum_file_bytes,
         {:ok, content} <- File.read(expanded),
         {:ok, values} <- parse(content),
         :ok <- Secrets.validate_values(%{values: values}) do
      {:ok, values}
    else
      false -> {:error, :local_secret_file_too_large}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:local_secret_file, error.__struct__}}
  end

  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(content) when is_binary(content) do
    if String.valid?(content) do
      content
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, %{}}, &parse_line/2)
    else
      {:error, {:invalid_local_secret_file, :encoding}}
    end
  end

  defp parse_line({line, line_number}, {:ok, values}) do
    line = String.trim(line)

    line =
      if String.starts_with?(line, "export "),
        do: String.trim_leading(line, "export "),
        else: line

    cond do
      line == "" or String.starts_with?(line, "#") ->
        {:cont, {:ok, values}}

      true ->
        case String.split(line, "=", parts: 2) do
          [name, raw_value] -> add_value(String.trim(name), raw_value, line_number, values)
          _invalid -> {:halt, {:error, {:invalid_local_secret_file, line_number}}}
        end
    end
  end

  defp add_value(name, raw_value, line_number, values) do
    with true <- Regex.match?(@name, name),
         false <- Map.has_key?(values, name),
         {:ok, value} <- parse_value(String.trim(raw_value)) do
      {:cont, {:ok, Map.put(values, name, value)}}
    else
      _invalid -> {:halt, {:error, {:invalid_local_secret_file, line_number}}}
    end
  end

  defp parse_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    if byte_size(rest) >= 1 and :binary.last(rest) == quote do
      {:ok, binary_part(rest, 0, byte_size(rest) - 1)}
    else
      {:error, :unterminated_quote}
    end
  end

  defp parse_value(value), do: {:ok, value}

  defp repository_root(working_directory) do
    case System.cmd("git", ["-C", working_directory, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {root, 0} -> {:ok, root |> String.trim() |> Path.expand()}
      {_output, _status} -> {:error, :git_repository_required}
    end
  rescue
    _error -> {:error, :git_unavailable}
  end

  defp below_root(path, root) do
    relative = Path.relative_to(path, root)

    if relative != ".." and not String.starts_with?(relative, "../"),
      do: :ok,
      else: {:error, :local_secret_file_outside_repository}
  end

  defp regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_local_secret_file}
      {:error, :enoent} -> {:error, :local_secret_file_not_found}
      {:error, reason} -> {:error, {:local_secret_file_stat, reason}}
    end
  end

  defp ignored_by_git(path, root) do
    relative = Path.relative_to(path, root)

    case System.cmd("git", ["-C", root, "check-ignore", "--quiet", "--", relative],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, 1} -> {:error, :local_secret_file_not_ignored}
      {_output, _status} -> {:error, :git_ignore_check_failed}
    end
  rescue
    _error -> {:error, :git_unavailable}
  end
end
