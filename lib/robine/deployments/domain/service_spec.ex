defmodule Robine.Deployments.Domain.ServiceSpec do
  @moduledoc "Normalized desired state for one bounded deployment service."

  @roles [:application, :postgres, :object_storage, :ingress]
  @name ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @environment_key ~r/\A[A-Z][A-Z0-9_]{0,63}\z/
  @secret_name ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/
  @image ~r/\A[^\s:@]+(?:\/[^\s:@]+)*(?::[^\s@]+)?@sha256:[a-f0-9]{64}\z/
  @volume_name ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/

  @enforce_keys [
    :role,
    :name,
    :image,
    :command,
    :environment,
    :secret_environment,
    :volumes,
    :healthcheck,
    :spec_digest
  ]
  defstruct @enforce_keys

  @type role :: :application | :postgres | :object_storage | :ingress
  @type t :: %__MODULE__{
          role: role(),
          name: String.t(),
          image: String.t(),
          command: [String.t()],
          environment: %{optional(String.t()) => String.t()},
          secret_environment: %{optional(String.t()) => String.t()},
          volumes: [map()],
          healthcheck: map(),
          spec_digest: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_service_spec, atom()}}
  def new(attributes) when is_map(attributes) do
    with {:ok, role} <- normalize_role(value(attributes, :role)),
         {:ok, name} <- safe_name(value(attributes, :name)),
         {:ok, image} <- immutable_image(value(attributes, :image)),
         {:ok, command} <- command(value(attributes, :command, [])),
         {:ok, environment} <- environment(value(attributes, :environment, %{}), :plain),
         {:ok, secrets} <- environment(value(attributes, :secret_environment, %{}), :secret),
         true <- MapSet.disjoint?(MapSet.new(Map.keys(environment)), MapSet.new(Map.keys(secrets))),
         {:ok, volumes} <- volumes(value(attributes, :volumes, [])),
         {:ok, healthcheck} <- healthcheck(value(attributes, :healthcheck, %{})) do
      normalized = %{
        role: role,
        name: name,
        image: image,
        command: command,
        environment: environment,
        secret_environment: secrets,
        volumes: volumes,
        healthcheck: healthcheck
      }

      {:ok, struct!(__MODULE__, Map.put(normalized, :spec_digest, digest(normalized)))}
    else
      false -> {:error, {:invalid_service_spec, :environment_collision}}
      {:error, reason} -> {:error, {:invalid_service_spec, reason}}
    end
  end

  def new(_attributes), do: {:error, {:invalid_service_spec, :shape}}

  @spec roles() :: [role()]
  def roles, do: @roles

  defp normalize_role(role) when role in @roles, do: {:ok, role}

  defp normalize_role(role) when is_binary(role) do
    case Enum.find(@roles, &(Atom.to_string(&1) == role)) do
      nil -> {:error, :role}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_role(_role), do: {:error, :role}

  defp safe_name(name) when is_binary(name) do
    if Regex.match?(@name, name), do: {:ok, name}, else: {:error, :name}
  end

  defp safe_name(_name), do: {:error, :name}

  defp immutable_image(image) when is_binary(image) do
    if byte_size(image) <= 512 and Regex.match?(@image, image),
      do: {:ok, image},
      else: {:error, :image}
  end

  defp immutable_image(_image), do: {:error, :image}

  defp command(arguments) when is_list(arguments) and length(arguments) <= 32 do
    if Enum.all?(arguments, &(is_binary(&1) and byte_size(&1) in 1..1024)),
      do: {:ok, arguments},
      else: {:error, :command}
  end

  defp command(_arguments), do: {:error, :command}

  defp environment(values, kind) when is_map(values) and map_size(values) <= 64 do
    valid? = fn
      {key, value} when is_binary(key) and is_binary(value) ->
        Regex.match?(@environment_key, key) and byte_size(value) <= 4096 and
          (kind == :plain or Regex.match?(@secret_name, value))

      _entry ->
        false
    end

    if Enum.all?(values, valid?), do: {:ok, values}, else: {:error, :environment}
  end

  defp environment(_values, _kind), do: {:error, :environment}

  defp volumes(values) when is_list(values) and length(values) <= 16 do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case volume(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)
        names = Enum.map(normalized, & &1.name)
        paths = Enum.map(normalized, & &1.mount_path)

        if length(Enum.uniq(names)) == length(names) and length(Enum.uniq(paths)) == length(paths),
          do: {:ok, normalized},
          else: {:error, :volumes}

      error ->
        error
    end
  end

  defp volumes(_values), do: {:error, :volumes}

  defp volume(value) when is_map(value) do
    name = value(value, :name)
    mount_path = value(value, :mount_path)
    read_only = value(value, :read_only, false)

    if is_binary(name) and Regex.match?(@volume_name, name) and safe_absolute_path?(mount_path) and
         is_boolean(read_only) do
      {:ok, %{name: name, mount_path: mount_path, read_only: read_only}}
    else
      {:error, :volumes}
    end
  end

  defp volume(_value), do: {:error, :volumes}

  defp healthcheck(%{} = healthcheck) when map_size(healthcheck) == 0, do: {:ok, %{}}

  defp healthcheck(healthcheck) when is_map(healthcheck) do
    type = value(healthcheck, :type)
    timeout_ms = value(healthcheck, :timeout_ms, 30_000)

    valid =
      case type do
        type when type in [:tcp, "tcp"] ->
          port = value(healthcheck, :port)
          is_integer(port) and port in 1..65_535

        type when type in [:http, "http"] ->
          case URI.parse(value(healthcheck, :url, "")) do
            %URI{scheme: scheme, host: host, userinfo: nil}
            when scheme in ["http", "https"] and is_binary(host) ->
              true

            _uri ->
              false
          end

        _type ->
          false
      end

    if valid and is_integer(timeout_ms) and timeout_ms in 1_000..300_000,
      do: {:ok, Map.put(healthcheck, :timeout_ms, timeout_ms)},
      else: {:error, :healthcheck}
  end

  defp healthcheck(_healthcheck), do: {:error, :healthcheck}

  defp safe_absolute_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and Path.expand(path) == path and path != "/"
  end

  defp safe_absolute_path?(_path), do: false

  defp digest(normalized) do
    normalized
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

  defp value(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
