defmodule TmuxRmWeb.Router do
  use TmuxRmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TmuxRmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Stub auth pipelines — pass-through for now
  pipeline :require_auth do
  end

  pipeline :require_auth_token do
  end

  # Health check — unauthenticated
  scope "/", TmuxRmWeb do
    pipe_through :api

    get "/healthz", HealthController, :healthz
  end

  scope "/", TmuxRmWeb do
    pipe_through :browser

    live "/", SessionListLive, :index
    live "/terminal/:target", TerminalLive, :show
    get "/login", PageController, :home
    get "/settings", PageController, :home
  end
end
