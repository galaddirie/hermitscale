defmodule HermitscaleWeb.AppsEndpoint do
  @moduledoc """
  Serves `<slug>.<apps domain>` on its own listener, separate from
  `HermitscaleWeb.Endpoint`.

  It declares no sockets, static files, or router, so every path (including
  `/live`) reaches `HermitscaleWeb.AppProxy` and apps can run their own Phoenix
  LiveView or Livebook.
  """

  use Phoenix.Endpoint, otp_app: :hermitscale

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug HermitscaleWeb.AppProxy
end
