defmodule Robine.Release.Checksums do
  @moduledoc "Creates and verifies strict SHA-256 release manifests."

  @line ~r/\A([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)\z/

  @spec write([Path.t()], Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(files, manifest_path) when is_list(files) and files != [] do
    with {:ok, entries} <- entries(files),
         :ok <- File.mkdir_p(Path.dirname(manifest_path)),
         :ok <- atomic_write(manifest_path, render(entries)) do
      {:ok, manifest_path}
    end
  end

  @spec verify(Path.t(), Path.t()) :: :ok | {:error, term()}
  def verify(manifest_path, directory) do
    with {:ok, manifest} <- File.read(manifest_path),
         true <- byte_size(manifest) <= 1_048_576,
         {:ok, expected} <- parse(manifest),
         [] <- mismatches(expected, directory) do
      :ok
    else
      false -> {:error, :checksum_manifest_too_large}
      mismatches when is_list(mismatches) -> {:error, {:checksum_mismatch, mismatches}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entries(files) do
    entries =
      files
      |> Enum.map(fn path -> {Path.basename(path), path} end)
      |> Enum.sort_by(&elem(&1, 0))

    names = Enum.map(entries, &elem(&1, 0))

    cond do
      Enum.any?(entries, fn {name, path} ->
        not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/, name) or
            not File.regular?(path)
      end) ->
        {:error, :invalid_release_artifact}

      Enum.uniq(names) != names ->
        {:error, :duplicate_release_artifact}

      true ->
        {:ok, Enum.map(entries, fn {name, path} -> {digest(path), name} end)}
    end
  end

  defp render(entries),
    do: Enum.map_join(entries, "", fn {digest, name} -> "#{digest}  #{name}\n" end)

  defp parse(manifest) do
    lines = String.split(manifest, "\n", trim: true)

    parsed =
      Enum.map(lines, fn line ->
        case Regex.run(@line, line) do
          [_, digest, name] -> {:ok, {digest, name}}
          _invalid -> {:error, :invalid_checksum_manifest}
        end
      end)

    with true <- lines != [],
         true <- Enum.all?(parsed, &match?({:ok, _entry}, &1)),
         entries = Enum.map(parsed, fn {:ok, entry} -> entry end),
         names = Enum.map(entries, &elem(&1, 1)),
         true <- Enum.uniq(names) == names do
      {:ok, entries}
    else
      _invalid -> {:error, :invalid_checksum_manifest}
    end
  end

  defp mismatches(entries, directory) do
    for {expected, name} <- entries,
        path = Path.join(directory, name),
        not File.regular?(path) or not secure_equal?(digest(path), expected),
        do: name
  end

  defp digest(path) do
    path
    |> File.stream!(64 * 1_024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp atomic_write(path, content) do
    temporary = path <> ".#{Ecto.UUID.generate()}.tmp"

    with :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:checksum_write, reason}}
    end
  end
end
