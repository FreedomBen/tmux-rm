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

# Configurable log level (default: :info in prod, :debug in dev)
if log_level = System.get_env("LOGGER_LEVEL") do
  config :logger, level: String.to_existing_atom(log_level)
end

# Allow PORT override in dev (default 8888)
if config_env() == :dev do
  port = String.to_integer(System.get_env("PORT") || "8888")

  config :termigate, TermigateWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port]
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "8888")
  bind_ip = if System.get_env("PHX_BIND") == "0.0.0.0", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

  config :termigate, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :termigate, TermigateWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: bind_ip, port: port],
    secret_key_base: secret_key_base,
    server: true
end
