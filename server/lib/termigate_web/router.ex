defmodule TermigateWeb.Router do
  use TermigateWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TermigateWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_auth do
    plug TermigateWeb.Plugs.RequireAuth
  end

  pipeline :require_auth_token do
    plug TermigateWeb.Plugs.RequireAuthToken
  end

  pipeline :rate_limit_login do
    plug TermigateWeb.Plugs.RateLimit, key: :login
  end

  pipeline :rate_limit_mcp do
    plug TermigateWeb.Plugs.RateLimit, key: :mcp
  end

  # MCP - AI agent access
  scope "/mcp" do
    pipe_through [:require_auth_token, :rate_limit_mcp]

    forward "/", Hermes.Server.Transport.StreamableHTTP.Plug, server: Termigate.MCP.Server
  end

  # Health check & metrics — unauthenticated
  scope "/", TermigateWeb do
    pipe_through :api
    get "/healthz", HealthController, :healthz
    get "/metrics", MetricsController, :index
  end

  # API - public
  scope "/api", TermigateWeb do
    pipe_through [:api, :rate_limit_login]
    post "/login", AuthController, :login
  end

  # API - authenticated
  scope "/api", TermigateWeb do
    pipe_through [:api, :require_auth_token]

    get "/sessions", SessionController, :index
    post "/sessions", SessionController, :create
    delete "/sessions/:name", SessionController, :delete
    put "/sessions/:name", SessionController, :update
    post "/sessions/:name/windows", SessionController, :create_window

    post "/panes/:target/split", PaneController, :split
    delete "/panes/:target", PaneController, :delete

    get "/config", ConfigController, :show
    put "/quick-actions/order", QuickActionController, :reorder
    resources "/quick-actions", QuickActionController, only: [:index, :create, :update, :delete]
  end

  # Unauthenticated web routes
  scope "/", TermigateWeb do
    pipe_through :browser

    live_session :unauthenticated do
      live "/login", AuthLive, :index
      live "/setup", SetupLive, :index
    end

    post "/login", AuthController, :web_login
    delete "/logout", AuthController, :logout
  end

  # Authenticated web routes
  scope "/", TermigateWeb do
    pipe_through [:browser, :require_auth]

    live_session :authenticated, on_mount: [{TermigateWeb.AuthHook, :default}] do
      live "/", SessionListLive, :index
      live "/sessions/:session", MultiPaneLive, :session
      live "/sessions/:session/windows/:window", MultiPaneLive, :window
      live "/settings", SettingsLive, :index
    end
  end
end
