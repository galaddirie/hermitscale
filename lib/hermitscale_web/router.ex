defmodule HermitscaleWeb.Router do
  use HermitscaleWeb, :router

  import HermitscaleWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HermitscaleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HermitscaleWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/auth/sign-in", AuthController, :sign_in
    get "/auth/workos/callback", AuthController, :callback
  end

  scope "/", HermitscaleWeb do
    pipe_through [:browser, :require_authenticated_user]

    delete "/users/log-out", AuthController, :delete
  end

  if Application.compile_env(:hermitscale, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HermitscaleWeb.Telemetry
    end
  end
end
