defmodule Robine.Workflows.Domain.CronExpression do
  @moduledoc "Pure bounded parser and UTC matcher for five-field cron expressions."

  @enforce_keys [:raw, :minute, :hour, :day, :month, :weekday, :day_wildcard, :weekday_wildcard]
  defstruct [:raw, :minute, :hour, :day, :month, :weekday, :day_wildcard, :weekday_wildcard]

  @type t :: %__MODULE__{
          raw: String.t(),
          minute: MapSet.t(non_neg_integer()),
          hour: MapSet.t(non_neg_integer()),
          day: MapSet.t(pos_integer()),
          month: MapSet.t(pos_integer()),
          weekday: MapSet.t(non_neg_integer()),
          day_wildcard: boolean(),
          weekday_wildcard: boolean()
        }

  @fields [minute: {0, 59}, hour: {0, 23}, day: {1, 31}, month: {1, 12}, weekday: {0, 7}]

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_cron}
  def parse(raw)
      when is_binary(raw) and byte_size(raw) in 1..100 do
    if String.valid?(raw) do
      with fields when length(fields) == 5 <- String.split(raw, ~r/\s+/, trim: true),
           {:ok, parsed} <- parse_fields(fields) do
        {:ok,
         %__MODULE__{
           raw: Enum.join(fields, " "),
           minute: parsed.minute.values,
           hour: parsed.hour.values,
           day: parsed.day.values,
           month: parsed.month.values,
           weekday: normalize_weekday(parsed.weekday.values),
           day_wildcard: parsed.day.wildcard,
           weekday_wildcard: parsed.weekday.wildcard
         }}
      else
        _invalid -> {:error, :invalid_cron}
      end
    else
      {:error, :invalid_cron}
    end
  end

  def parse(_raw), do: {:error, :invalid_cron}

  @spec matches?(t(), DateTime.t()) :: boolean()
  def matches?(%__MODULE__{} = expression, %DateTime{} = datetime) do
    if datetime.utc_offset + datetime.std_offset == 0 do
      weekday = rem(Date.day_of_week(DateTime.to_date(datetime)), 7)

      MapSet.member?(expression.minute, datetime.minute) and
        MapSet.member?(expression.hour, datetime.hour) and
        MapSet.member?(expression.month, datetime.month) and
        day_matches?(expression, datetime.day, weekday)
    else
      false
    end
  end

  defp day_matches?(%{day_wildcard: true, weekday_wildcard: true}, _day, _weekday), do: true

  defp day_matches?(%{day_wildcard: true, weekday: weekdays}, _day, weekday),
    do: MapSet.member?(weekdays, weekday)

  defp day_matches?(%{weekday_wildcard: true, day: days}, day, _weekday),
    do: MapSet.member?(days, day)

  defp day_matches?(expression, day, weekday),
    do: MapSet.member?(expression.day, day) or MapSet.member?(expression.weekday, weekday)

  defp parse_fields(fields) do
    @fields
    |> Enum.zip(fields)
    |> Enum.reduce_while({:ok, %{}}, fn {{name, {minimum, maximum}}, field}, {:ok, parsed} ->
      case parse_field(field, minimum, maximum) do
        {:ok, value} -> {:cont, {:ok, Map.put(parsed, name, value)}}
        :error -> {:halt, {:error, :invalid_cron}}
      end
    end)
  end

  defp parse_field(field, minimum, maximum) do
    segments = String.split(field, ",", trim: false)

    with false <- Enum.any?(segments, &(&1 == "")),
         {:ok, values} <- parse_segments(segments, minimum, maximum) do
      {:ok, %{values: MapSet.new(values), wildcard: field == "*"}}
    else
      _invalid -> :error
    end
  end

  defp parse_segments(segments, minimum, maximum) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, values} ->
      case parse_segment(segment, minimum, maximum) do
        {:ok, parsed} -> {:cont, {:ok, values ++ parsed}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp parse_segment(segment, minimum, maximum) do
    case String.split(segment, "/", parts: 2) do
      [base] ->
        base_values(base, minimum, maximum, 1)

      [base, step] ->
        with {:ok, parsed_step} <- integer(step),
             true <- parsed_step > 0 do
          base_values(base, minimum, maximum, parsed_step)
        else
          _invalid -> :error
        end
    end
  end

  defp base_values("*", minimum, maximum, step),
    do: {:ok, Enum.take_every(minimum..maximum, step)}

  defp base_values(base, minimum, maximum, step) do
    case String.split(base, "-", parts: 2) do
      [single] ->
        with {:ok, value} <- integer(single),
             true <- value in minimum..maximum do
          values = if step == 1, do: [value], else: Enum.take_every(value..maximum, step)
          {:ok, values}
        else
          _invalid -> :error
        end

      [first, last] ->
        with {:ok, first} <- integer(first),
             {:ok, last} <- integer(last),
             true <- first in minimum..maximum and last in minimum..maximum and first <= last do
          {:ok, Enum.take_every(first..last, step)}
        else
          _invalid -> :error
        end
    end
  end

  defp integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp normalize_weekday(values) do
    values
    |> Enum.map(&if(&1 == 7, do: 0, else: &1))
    |> MapSet.new()
  end
end
