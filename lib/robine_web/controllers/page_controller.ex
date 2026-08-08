defmodule RobineWeb.PageController do
  use RobineWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
