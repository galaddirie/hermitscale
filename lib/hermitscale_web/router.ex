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

  pipeline :workos_webhook do
    plug :accepts, ["json"]
  end

  scope "/hooks", HermitscaleWeb do
    pipe_through :api

    post "/:token", WebhookController, :inbound
    post "/:token/*rest", WebhookController, :inbound
  end

  scope "/webhooks", HermitscaleWeb do
    pipe_through :workos_webhook

    post "/workos/:endpoint_token", WorkOSWebhookController, :create
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

  ## Authentication routes

  scope "/", HermitscaleWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home

    live_session :require_authenticated_user,
      on_mount: [{HermitscaleWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/connected-accounts", ConnectedAccountsLive, :index
    end

    delete "/users/log-out", AuthController, :delete
    delete "/users/account", AccountDeletionController, :delete
    post "/organizations/:id/switch", OrganizationSessionController, :update

    post "/users/settings/connected-accounts/:provider/connect",
         ConnectedAccountController,
         :create

    patch "/users/settings/connected-accounts/:provider/sharing",
          ConnectedAccountController,
          :update

    delete "/users/settings/connected-accounts/:provider",
           ConnectedAccountController,
           :delete
  end

  scope "/", HermitscaleWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{HermitscaleWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
    end

    get "/auth/sign-in", AuthController, :sign_in
    get "/auth/workos/callback", AuthController, :callback
  end
end
