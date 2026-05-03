defmodule TermigateWeb.Plugs.RequireAuth do
  @moduledoc "Redirects to /login if no auth session cookie is present or session has expired."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if Termigate.Auth.auth_enabled?() do
      case get_session(conn, "authenticated_at") do
        nil ->
          Logger.debug("Auth rejected: no session cookie, ip=#{remote_ip(conn)}")
          conn |> redirect(to: "/login") |> halt()

        timestamp ->
          max_age = Termigate.Auth.session_ttl_seconds()
          session_version = get_session(conn, "auth_version")
          current_version = Termigate.Auth.auth_version()

          cond do
            System.system_time(:second) - timestamp > max_age ->
              Logger.info("Auth session expired, ip=#{remote_ip(conn)}")
              conn |> clear_session() |> redirect(to: "/login") |> halt()

            not is_binary(session_version) or session_version != current_version ->
              Logger.info("Auth session revoked (credential rotation), ip=#{remote_ip(conn)}")

              conn |> clear_session() |> redirect(to: "/login") |> halt()

            true ->
              conn
          end
      end
    else
      conn |> redirect(to: "/setup") |> halt()
    end
  end

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
