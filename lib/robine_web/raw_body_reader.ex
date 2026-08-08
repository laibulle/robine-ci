defmodule RobineWeb.RawBodyReader do
  @moduledoc false

  def read_body(conn, options) do
    case Plug.Conn.read_body(conn, options) do
      {:ok, body, conn} -> {:ok, body, store(conn, body)}
      {:more, body, conn} -> {:more, body, store(conn, body)}
      other -> other
    end
  end

  defp store(conn, body) do
    previous = conn.private[:raw_body] || <<>>
    Plug.Conn.put_private(conn, :raw_body, previous <> body)
  end
end
