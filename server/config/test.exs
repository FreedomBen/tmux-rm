import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :termigate, TermigateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ipqUh7eVOZMj4LbuWMqTqKKWmbG9PpRGSfhrzg9CXyys/V5DzdM6ICJkr1aT1xEG",
  server: false

config :termigate,
  command_runner: Termigate.StubCommandRunner,
  pane_stream_grace_period: 100,
  fifo_dir: "/tmp/termigate-test",
  config_path: "/tmp/termigate-test/config.yaml",
  session_poll_interval: 500,
  config_poll_interval: 500,
  output_coalesce_ms: 0

# Print only errors during test
config :logger, level: :error

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
