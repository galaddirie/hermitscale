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
    pipe_through :api
    post "/inference/v1/responses", InferenceController, :create
  end

  # ExMCP owns content negotiation and sessions; execution capabilities authenticate
  # every request independently of browser cookies.
  scope "/", HermitscaleWeb do
    forward "/mcp", MCP
  end

  scope "/", HermitscaleWeb do
    match :*, "/gateway/:token/*path", AppGatewayController, :proxy
  end

  # The handoff already retained a rotated seal; do not refresh the old cookie again.
  pipeline :session_refresh do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HermitscaleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", HermitscaleWeb do
    pipe_through :session_refresh
    get "/auth/session-refresh/:nonce", AuthController, :session_refresh
  end

  scope "/", HermitscaleWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/auth/login", AuthController, :login
    get "/auth/workos/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :logout
  end

  scope "/", HermitscaleWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{HermitscaleWeb.UserAuth, :require_authenticated}] do
      live "/agents", AgentLive, :index
      live "/agents/:id", AgentLive, :show
      live "/apps", AppLive, :index
      live "/apps/:id", AppLive, :show
      live "/apps/:id/build", AppLive, :build
      live "/apps/:id/deployments/:deployment_id", AppLive, :deployment
      live "/reviews", ReviewsLive, :index
      live "/reviews/:id", ReviewsLive, :show
      live "/workflows", WorkflowLive, :index
      live "/workflows/:id", WorkflowLive, :show
    end

    get "/apps/:id/previews/:preview_id/open", AppAccessController, :open
    get "/apps/:id/environments/:environment_id/open", AppAccessController, :open_environment
    post "/api/capabilities", CapabilityController, :create
    get "/artifacts/:id", ArtifactController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", HermitscaleWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:hermitscale, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HermitscaleWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
