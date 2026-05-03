import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("PHX_SERVER") do
  config :termigate, TermigateWeb.Endpoint, server: true
end

# Auth token from environment
if auth_token = System.get_env("TERMIGATE_AUTH_TOKEN") do
  config :termigate, auth_token: auth_token
end

# Optional tmux socket path
if socket = System.get_env("TERMIGATE_TMUX_SOCKET") do
  config :termigate, tmux_socket: socket
end

# Optional CORS origin
if cors_origin = System.get_env("TERMIGATE_CORS_ORIGIN") do
  config :termigate, cors_origin: cors_origin
end

# Optional metrics endpoint token
if metrics_token = System.get_env("TERMIGATE_METRICS_TOKEN") do
  config :termigate, metrics_token: metrics_token
end

# Mark the session cookie `Secure` so browsers withhold it on plain-HTTP
# requests. Read at runtime so flipping `TERMIGATE_SECURE_COOKIES` on a built
# release only requires a process restart, not a rebuild. Consumed by
# `TermigateWeb.Endpoint.runtime_session_options/0`, which also tightens
# `same_site` to `"Strict"` whenever Secure is on.
#
# Default: disabled. `force_ssl`'s exclude list keeps loopback and the Android
# emulator host alias (`10.0.2.2`) reachable over plain HTTP; flipping the
# secure flag on by default would block those clients from logging in. Opt in
# with `TERMIGATE_SECURE_COOKIES=true` when the deployment is reached only
# over HTTPS. Only the exact string "true" enables the flag — typos like
# "yes", "1", or "TRUE" stay off so a careless setting never silently locks
# out plain-HTTP clients.
secure_cookies =
  case System.get_env("TERMIGATE_SECURE_COOKIES") do
    "true" -> true
    _ -> false
  end

config :termigate, secure_cookies: secure_cookies

# Opt in to exposing /metrics on the public listener. By default the endpoint
# only answers requests from loopback peers (127.0.0.0/8, ::1) so a fresh
# deployment does not leak operational fingerprinting data to the internet.
if System.get_env("TERMIGATE_PUBLIC_METRICS") == "true" do
  config :termigate, public_metrics: true
end

# Trusted reverse-proxy CIDRs (comma-separated). When set, X-Forwarded-For
# from these proxies is honored so rate limits and audit logs see the real
# client IP instead of the proxy address. Default is empty: X-Forwarded-For
# is ignored and conn.remote_ip stays as the socket peer.
trusted_proxies =
  case System.get_env("TERMIGATE_TRUSTED_PROXIES") do
    nil ->
      []

    val ->
      val
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

config :termigate, trusted_proxies: trusted_proxies

# Configurable log level (default: :info in prod, :debug in dev)
if log_level = System.get_env("LOGGER_LEVEL") do
  config :logger, level: String.to_existing_atom(log_level)
end

# Allow PORT override in dev (default 8888)
if config_env() == :dev do
  port = String.to_integer(System.get_env("PORT") || "8888")

  config :termigate, TermigateWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: port]
end

if config_env() == :prod do
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil ->
        raise """
        environment variable SECRET_KEY_BASE is missing.
        Generate one with: mix phx.gen.secret  (or: openssl rand -base64 48)
        """

      "" ->
        raise """
        environment variable SECRET_KEY_BASE is empty.
        Generate one with: mix phx.gen.secret  (or: openssl rand -base64 48)
        """

      "CHANGE_ME" <> _ ->
        raise """
        environment variable SECRET_KEY_BASE is the deploy template placeholder.
        Generate one with: mix phx.gen.secret  (or: openssl rand -base64 48)
        """

      "generate-me" ->
        raise """
        environment variable SECRET_KEY_BASE is the deploy template placeholder.
        Generate one with: mix phx.gen.secret  (or: openssl rand -base64 48)
        """

      value when byte_size(value) < 32 ->
        raise """
        environment variable SECRET_KEY_BASE is too short (need >= 32 bytes).
        Generate one with: mix phx.gen.secret  (or: openssl rand -base64 48)
        """

      value ->
        value
    end

  configured_host = System.get_env("PHX_HOST")
  host = configured_host || "localhost"
  port = String.to_integer(System.get_env("PORT") || "8888")
  bind_ip = if System.get_env("PHX_BIND") == "0.0.0.0", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

  # WebSocket origin check: default to :conn, which validates the WS handshake
  # Origin against the request's Host header. This works regardless of PHX_HOST
  # for the common single-origin case (browsers loading and WS-upgrading to the
  # same hostname/IP), so it's safe for rootless podman, LAN IPs, Tailscale, etc.
  # Operators who deliberately need cross-origin handshakes can opt out with
  # TERMIGATE_CHECK_ORIGIN=false, or pin to an explicit allowlist.
  check_origin =
    case System.get_env("TERMIGATE_CHECK_ORIGIN") do
      nil -> :conn
      "false" -> false
      "true" -> true
      "conn" -> :conn
      val -> val |> String.split(",") |> Enum.map(&String.trim/1)
    end

  if bind_ip == {0, 0, 0, 0} and configured_host in [nil, "localhost"] do
    require Logger

    Logger.warning(
      "termigate is binding 0.0.0.0 with PHX_HOST=localhost. URL generation " <>
        "(absolute links, redirects) will use 'localhost'. Set PHX_HOST to the " <>
        "address users will visit (e.g. 127.0.0.1, your LAN IP, or DNS name) " <>
        "to silence this warning."
    )
  end

  config :termigate, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :termigate, TermigateWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: bind_ip, port: port],
    secret_key_base: secret_key_base,
    check_origin: check_origin,
    server: true
end
