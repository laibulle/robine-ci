defmodule Robine.Deployments.Domain.Environment do
  @moduledoc "A protected native deployment target and its immutable desired state."

  alias Robine.Deployments.Domain.ServiceSpec

  @name ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @label ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  @migration_policies [:application_only, :forward_only, :rollback_safe]

  @enforce_keys [
    :id,
    :repository_id,
    :name,
    :protection,
    :runner_labels,
    :deployment_root,
    :network_name,
    :timeout_ms,
    :migration_policy,
    :verification,
    :services,
    :desired_state_digest,
    :inserted_at,
    :updated_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_environment, atom()}}
  def new(attributes) when is_map(attributes) do
    with {:ok, id} <- identifier(value(attributes, :id), :id),
         {:ok, repository_id} <- identifier(value(attributes, :repository_id), :repository_id),
         {:ok, name} <- name(value(attributes, :name)),
         {:ok, protection} <- protection(value(attributes, :protection)),
         {:ok, runner_labels} <- runner_labels(value(attributes, :runner_labels, [])),
         {:ok, root} <- deployment_root(value(attributes, :deployment_root)),
         {:ok, network} <- network_name(value(attributes, :network_name)),
         {:ok, timeout} <- timeout(value(attributes, :timeout_ms, 1_200_000)),
         {:ok, migration_policy} <- migration_policy(value(attributes, :migration_policy)),
         {:ok, verification} <- verification(value(attributes, :verification)),
         {:ok, services} <- services(value(attributes, :services)),
         {:ok, inserted_at} <- timestamp(value(attributes, :inserted_at), :inserted_at),
         {:ok, updated_at} <- timestamp(value(attributes, :updated_at), :updated_at) do
      desired = %{
        deployment_root: root,
        network_name: network,
        migration_policy: migration_policy,
        verification: verification,
        services: Enum.map(services, &Map.from_struct/1)
      }

      {:ok,
       %__MODULE__{
         id: id,
         repository_id: repository_id,
         name: name,
         protection: protection,
         runner_labels: runner_labels,
         deployment_root: root,
         network_name: network,
         timeout_ms: timeout,
         migration_policy: migration_policy,
         verification: verification,
         services: services,
         desired_state_digest: digest(desired),
         inserted_at: inserted_at,
         updated_at: updated_at
       }}
    else
      {:error, reason} -> {:error, {:invalid_environment, reason}}
    end
  end

  def new(_attributes), do: {:error, {:invalid_environment, :shape}}

  defp identifier(value, field) when is_binary(value) do
    if value != "", do: {:ok, value}, else: {:error, field}
  end

  defp identifier(_value, field), do: {:error, field}

  defp name(value) when is_binary(value) do
    if Regex.match?(@name, value), do: {:ok, value}, else: {:error, :name}
  end

  defp name(_value), do: {:error, :name}

  defp protection(value) when value in [:unprotected, :protected], do: {:ok, value}
  defp protection("unprotected"), do: {:ok, :unprotected}
  defp protection("protected"), do: {:ok, :protected}
  defp protection(_value), do: {:error, :protection}

  defp runner_labels(labels) when is_list(labels) and length(labels) in 1..16 do
    if Enum.all?(labels, &(is_binary(&1) and Regex.match?(@label, &1))) do
      {:ok, Enum.uniq(labels)}
    else
      {:error, :runner_labels}
    end
  end

  defp runner_labels(_labels), do: {:error, :runner_labels}

  defp deployment_root(path) when is_binary(path) do
    if String.starts_with?(path, "/") and Path.expand(path) == path and path != "/" and
         byte_size(path) <= 512,
       do: {:ok, path},
       else: {:error, :deployment_root}
  end

  defp deployment_root(_path), do: {:error, :deployment_root}

  defp network_name(value) when is_binary(value) do
    if Regex.match?(@label, value), do: {:ok, value}, else: {:error, :network_name}
  end

  defp network_name(_value), do: {:error, :network_name}

  defp timeout(value) when is_integer(value) and value in 60_000..7_200_000, do: {:ok, value}
  defp timeout(_value), do: {:error, :timeout_ms}

  defp migration_policy(value) when value in @migration_policies, do: {:ok, value}

  defp migration_policy(value) when is_binary(value) do
    case Enum.find(@migration_policies, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :migration_policy}
      policy -> {:ok, policy}
    end
  end

  defp migration_policy(_value), do: {:error, :migration_policy}

  defp verification(value) when is_map(value) do
    url = value(value, :url)
    expected_status = value(value, :expected_status, 200..299)
    version_path = value(value, :version_path)

    with %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(url || ""),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         {:ok, status} <- status_range(expected_status),
         true <- is_nil(version_path) or safe_version_path?(version_path) do
      {:ok, %{url: url, expected_status: status, version_path: version_path}}
    else
      _reason -> {:error, :verification}
    end
  end

  defp verification(_value), do: {:error, :verification}

  defp status_range(%Range{first: first, last: last})
       when first in 100..599 and last in 100..599 and first <= last,
       do: {:ok, %{first: first, last: last}}

  defp status_range(%{"first" => first, "last" => last}), do: status_range(first..last//1)
  defp status_range(%{first: first, last: last}), do: status_range(first..last//1)
  defp status_range(_value), do: {:error, :status}

  defp safe_version_path?(path) when is_binary(path) do
    byte_size(path) in 1..128 and String.starts_with?(path, "/") and
      not String.contains?(path, "..")
  end

  defp safe_version_path?(_path), do: false

  defp services(values) when is_list(values) and length(values) in 1..4 do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case ServiceSpec.new(value) do
        {:ok, service} -> {:cont, {:ok, [service | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, services} -> validate_service_set(Enum.reverse(services))
      {:error, _reason} -> {:error, :services}
    end
  end

  defp services(_values), do: {:error, :services}

  defp validate_service_set(services) do
    roles = Enum.map(services, & &1.role)
    names = Enum.map(services, & &1.name)

    if Enum.count(roles, &(&1 == :application)) == 1 and
         length(Enum.uniq(roles)) == length(roles) and length(Enum.uniq(names)) == length(names) do
      {:ok, services}
    else
      {:error, :services}
    end
  end

  defp timestamp(%DateTime{} = value, _field), do: {:ok, value}
  defp timestamp(_value, field), do: {:error, field}

  defp digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
