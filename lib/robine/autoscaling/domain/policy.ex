defmodule Robine.Autoscaling.Domain.Policy do
  @moduledoc "Provider-neutral autoscaling policy and its safety boundaries."

  @enforce_keys [
    :id,
    :name,
    :provider,
    :runner_template,
    :labels,
    :min_runners,
    :max_runners,
    :concurrency,
    :idle_timeout_seconds,
    :scale_up_cooldown_seconds,
    :scale_down_cooldown_seconds,
    :enabled
  ]
  defstruct @enforce_keys ++ [:inserted_at, :updated_at]

  @type t :: %__MODULE__{}

  @label ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/

  def new(input) when is_map(input) do
    policy = %__MODULE__{
      id: Map.get(input, :id),
      name: Map.get(input, :name),
      provider: Map.get(input, :provider),
      runner_template: Map.get(input, :runner_template, %{}),
      labels: Map.get(input, :labels, ["docker"]),
      min_runners: Map.get(input, :min_runners, 0),
      max_runners: Map.get(input, :max_runners),
      concurrency: Map.get(input, :concurrency, 1),
      idle_timeout_seconds: Map.get(input, :idle_timeout_seconds, 600),
      scale_up_cooldown_seconds: Map.get(input, :scale_up_cooldown_seconds, 30),
      scale_down_cooldown_seconds: Map.get(input, :scale_down_cooldown_seconds, 300),
      enabled: Map.get(input, :enabled, false),
      inserted_at: Map.get(input, :inserted_at),
      updated_at: Map.get(input, :updated_at)
    }

    validate(policy)
  end

  def new(_input), do: {:error, :invalid_autoscaling_policy}

  defp validate(policy) do
    cond do
      not (is_binary(policy.id) and is_binary(policy.name) and String.trim(policy.name) != "") ->
        {:error, :invalid_autoscaling_identity}

      not (is_binary(policy.provider) and byte_size(policy.provider) in 1..63) ->
        {:error, :invalid_autoscaling_provider}

      not (is_map(policy.runner_template) and map_size(policy.runner_template) <= 64) ->
        {:error, :invalid_runner_template}

      not valid_labels?(policy.labels) ->
        {:error, :invalid_autoscaling_labels}

      not (is_integer(policy.min_runners) and is_integer(policy.max_runners) and
             policy.min_runners >= 0 and policy.max_runners >= policy.min_runners and
               policy.max_runners <= 10_000) ->
        {:error, :invalid_autoscaling_bounds}

      not (is_integer(policy.concurrency) and policy.concurrency in 1..64) ->
        {:error, :invalid_autoscaling_concurrency}

      not Enum.all?(
        [
          policy.idle_timeout_seconds,
          policy.scale_up_cooldown_seconds,
          policy.scale_down_cooldown_seconds
        ],
        &(is_integer(&1) and &1 >= 0)
      ) ->
        {:error, :invalid_autoscaling_timing}

      not is_boolean(policy.enabled) ->
        {:error, :invalid_autoscaling_state}

      true ->
        {:ok, %{policy | name: String.trim(policy.name), labels: Enum.uniq(policy.labels)}}
    end
  end

  defp valid_labels?(labels),
    do:
      is_list(labels) and labels != [] and length(labels) <= 32 and
        Enum.all?(labels, &(is_binary(&1) and Regex.match?(@label, &1)))
end
