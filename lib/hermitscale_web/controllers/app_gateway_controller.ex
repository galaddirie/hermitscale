defmodule HermitscaleWeb.AppGatewayController do
  use HermitscaleWeb, :controller

  def proxy(conn, %{"token" => token, "path" => path}),
    do: HermitscaleWeb.AppGateway.proxy(conn, token, path)
end
