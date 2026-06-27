defmodule HermitscaleWeb.PageController do
  use HermitscaleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
