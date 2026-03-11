defmodule TmuxRmWeb.Plugs.RequireAuth do
  @moduledoc "Redirects to /login if no auth session cookie is present."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if TmuxRm.Auth.auth_enabled?() do
      case get_session(conn, "authenticated_at") do
        nil ->
          conn |> redirect(to: "/login") |> halt()

        _timestamp ->
          conn
      end
    else
      conn
    end
  end
end
