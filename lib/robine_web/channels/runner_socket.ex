defmodule RobineWeb.RunnerSocket do
  use Phoenix.Socket

  alias Robine.Runners
  alias Robine.Runtime.Dependencies

  channel "runner:v1", RobineWeb.RunnerChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with {:ok, runner_id} <- header(connect_info, "x-robine-runner-id"),
         {:ok, credential} <- header(connect_info, "x-robine-runner-credential"),
         correlation_id = Ecto.UUID.generate(),
         context =
           Dependencies.context(
             %{id: "anonymous:runner-socket", role: :runner},
             correlation_id
           ),
         {:ok, runner} <-
           Runners.authenticate(%{runner_id: runner_id, credential: credential}, context) do
      {:ok,
       socket
       |> assign(:runner_id, runner.runner_id)
       |> assign(:correlation_id, correlation_id)}
    else
      _error -> :error
    end
  end

  @impl true
  def id(socket), do: "runner_socket:#{socket.assigns.runner_id}"

  defp header(%{x_headers: headers}, wanted) when is_list(headers) do
    case Enum.find_value(headers, fn
           {key, value} when is_binary(key) and is_binary(value) ->
             if String.downcase(key) == wanted, do: value

           _header ->
             nil
         end) do
      nil -> {:error, :missing_header}
      value -> {:ok, value}
    end
  end

  defp header(_connect_info, _wanted), do: {:error, :missing_header}
end
