defmodule TmuxRmWeb.Plugs.RequireAuth do
  @moduledoc "Redirects to /login if no auth session cookie is present or session has expired."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if TmuxRm.Auth.auth_enabled?() do
      case get_session(conn, "authenticated_at") do
        nil ->
          conn |> redirect(to: "/login") |> halt()

        timestamp ->
          max_age = TmuxRm.Auth.session_ttl_seconds()

          if System.system_time(:second) - timestamp > max_age do
            conn |> clear_session() |> redirect(to: "/login") |> halt()
          else
            conn
          end
      end
    else
      conn |> redirect(to: "/setup") |> halt()
    end
  end
end
