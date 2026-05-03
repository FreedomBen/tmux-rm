defmodule TermigateWeb.Plugs.RequireSetupAccess do
  @moduledoc """
  Gates `/setup` HTTP requests on a valid one-shot token.

  Once an admin already exists, this plug passes through (`SetupLive` will
  redirect to `/login`). While no admin exists, only requests that carry a
  `?token=...` matching `Termigate.Setup.token/0` are allowed; everything
  else gets a 404.

  The token is 32 random bytes (256 bits) URL-safe-base64 encoded, single
  use, and burned the moment an admin is created. We previously also
  required the peer to be on loopback, but containerised deploys NAT the
  source IP to the bridge gateway so the host-side browser can never reach
  the form — the only documented setup path was unreachable in the most
  common topology. The token alone now carries the gate.

  This plug only protects the initial HTTP GET. The LiveView form
  submission rides the WebSocket and bypasses HTTP plugs, so
  `TermigateWeb.SetupLive` re-validates the token in `mount/3` and again in
  the `setup` event handler.
  """
  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if Termigate.Auth.auth_enabled?() do
      conn
    else
      conn = fetch_query_params(conn)

      if Termigate.Setup.valid_token?(conn.query_params["token"]) do
        conn
      else
        deny(conn, "missing or invalid setup token")
      end
    end
  end

  defp deny(conn, reason) do
    Logger.warning("/setup access denied: #{reason}, ip=#{format_ip(conn.remote_ip)}")

    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
