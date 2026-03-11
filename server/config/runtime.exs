import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("PHX_SERVER") do
  config :tmux_rm, TmuxRmWeb.Endpoint, server: true
end

# Auth token from environment
if auth_token = System.get_env("RCA_AUTH_TOKEN") do
  config :tmux_rm, auth_token: auth_token
end

# Optional tmux socket path
if socket = System.get_env("RCA_TMUX_SOCKET") do
  config :tmux_rm, tmux_socket: socket
end

# Optional CORS origin
if cors_origin = System.get_env("RCA_CORS_ORIGIN") do
  config :tmux_rm, cors_origin: cors_origin
end

# Optional metrics endpoint token
if metrics_token = System.get_env("RCA_METRICS_TOKEN") do
  config :tmux_rm, metrics_token: metrics_token
end

# Configurable log level (default: :info in prod, :debug in dev)
if log_level = System.get_env("LOGGER_LEVEL") do
  config :logger, level: String.to_existing_atom(log_level)
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")
  bind_ip = if System.get_env("PHX_BIND") == "0.0.0.0", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

  config :tmux_rm, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tmux_rm, TmuxRmWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: bind_ip, port: port],
    secret_key_base: secret_key_base,
    server: true
end
