# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :termigate,
  generators: [timestamp_type: :utc_datetime],
  command_runner: Termigate.Tmux.CommandRunner,
  session_poll_interval: 3_000,
  pane_stream_grace_period: 30_000,
  ring_buffer_min_size: 524_288,
  ring_buffer_max_size: 8_388_608,
  ring_buffer_default_size: 2_097_152,
  memory_high_watermark: 805_306_368,
  max_pane_streams: 100,
  input_size_limit: 131_072,
  default_cols: 120,
  default_rows: 40,
  config_poll_interval: 2_000,
  fifo_dir: "/tmp/termigate",
  tmux_path: nil,
  tmux_socket: nil,
  output_coalesce_ms: 3,
  output_coalesce_max_bytes: 32_768,
  auth_session_ttl_days: 30,
  auth_token_max_age: 604_800,
  rate_limits: %{login: {5, 60}, session_create: {10, 60}, websocket: {10, 60}, mcp: {120, 60}}

# Configure the endpoint
config :termigate, TermigateWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TermigateWeb.ErrorHTML, json: TermigateWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Termigate.PubSub,
  live_view: [signing_salt: "rGgw7trH"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  termigate: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  termigate: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
