defmodule TmuxRmWeb.Plugs.RequireAuth do
  @moduledoc "Redirects to /login if no auth session cookie is present or session has expired."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if TmuxRm.Auth.auth_enabled?() do
      case get_session(conn, "authenticated_at") do
        nil ->
          Logger.debug("Auth rejected: no session cookie, ip=#{remote_ip(conn)}")
          conn |> redirect(to: "/login") |> halt()

        timestamp ->
          max_age = TmuxRm.Auth.session_ttl_seconds()

          if System.system_time(:second) - timestamp > max_age do
            Logger.info("Auth session expired, ip=#{remote_ip(conn)}")
            conn |> clear_session() |> redirect(to: "/login") |> halt()
          else
            conn
          end
      end
    else
      conn |> redirect(to: "/setup") |> halt()
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
