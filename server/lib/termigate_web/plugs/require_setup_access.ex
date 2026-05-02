defmodule TermigateWeb.Plugs.RequireSetupAccess do
  @moduledoc """
  Gates `/setup` HTTP requests on `loopback IP + valid one-shot token`.

  Once an admin already exists, this plug passes through (`SetupLive` will
  redirect to `/login`). While no admin exists, only requests that come
  from `127.0.0.1` / `::1` and carry a `?token=...` matching
  `Termigate.Setup.token/0` are allowed; everything else gets a 404.

  This plug only protects the initial HTTP GET. The LiveView form
  submission rides the WebSocket and bypasses HTTP plugs, so
  `TermigateWeb.SetupLive` re-validates the token in `mount/3` and again in
  the `setup` event handler.

  Note: behind a same-host reverse proxy `conn.remote_ip` is the proxy's
  loopback address, so the loopback gate alone is bypassable in fronted
  deploys. In that topology, operators should pre-seed
  `TERMIGATE_SETUP_TOKEN` so the token gate (which is not bypassable by
  proxying) carries the load.
  """
  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if Termigate.Auth.auth_enabled?() do
      conn
    else
      conn = fetch_query_params(conn)

      cond do
        not loopback?(conn.remote_ip) ->
          deny(conn, "non-loopback peer")

        not Termigate.Setup.valid_token?(conn.query_params["token"]) ->
          deny(conn, "missing or invalid setup token")

        true ->
          conn
      end
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp deny(conn, reason) do
    Logger.warning("/setup access denied: #{reason}, ip=#{format_ip(conn.remote_ip)}")

    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
