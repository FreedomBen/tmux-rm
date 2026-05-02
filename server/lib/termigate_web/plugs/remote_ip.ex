defmodule TermigateWeb.Plugs.RemoteIp do
  @moduledoc """
  Rewrites `conn.remote_ip` to the originating client when the request came
  through a trusted reverse proxy.

  Without this plug, `conn.remote_ip` is the socket peer — i.e. the proxy's
  IP — which collapses every IP-keyed rate limit and audit log line onto a
  single bucket per proxy.

  Configure trusted proxies via the `TERMIGATE_TRUSTED_PROXIES` env var
  (comma-separated CIDRs). With no configuration this plug is a no-op:
  `X-Forwarded-For` is ignored entirely and `conn.remote_ip` stays as the
  socket peer. Set the env var when termigate sits behind a reverse proxy.

  Operator note: this only protects when termigate is unreachable except
  through the configured proxy (typical: bind to loopback). If termigate
  is exposed to the network directly, attackers can still spoof
  `X-Forwarded-For` and bypass IP-based rate limits.
  """

  @behaviour Plug

  @impl true
  def init(_opts), do: :ok

  @impl true
  def call(conn, _opts) do
    case opts() do
      :disabled -> conn
      remote_ip_opts -> RemoteIp.call(conn, remote_ip_opts)
    end
  end

  defp opts do
    key = {__MODULE__, :opts}

    case :persistent_term.get(key, :missing) do
      :missing ->
        built = build_opts()
        :persistent_term.put(key, built)
        built

      built ->
        built
    end
  end

  defp build_opts do
    case Application.get_env(:termigate, :trusted_proxies, []) do
      [] -> :disabled
      proxies -> RemoteIp.init(proxies: proxies)
    end
  end
end
