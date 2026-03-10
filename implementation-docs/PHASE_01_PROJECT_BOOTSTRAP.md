# Phase 1: Project Bootstrap & Core Infrastructure

## Goal
Set up the Elixir/Phoenix project with all dependencies, configuration, and the supervision tree skeleton. After this phase, the app boots, serves a placeholder page, and has the process infrastructure ready for terminal streaming.

## Prerequisites
- Elixir 1.17+, OTP 27+, Phoenix 1.8, LiveView ~1.0
- tmux 2.6+ installed on the host
- Node.js (for esbuild/npm asset pipeline)

## Steps

### 1.1 Generate Phoenix Project
- `mix phx.new remote_code_agents --no-ecto --no-mailer --no-dashboard`
- No Ecto (no database), no mailer, no LiveDashboard
- Verify `mix.exs` has `remote_code_agents` as the project name

### 1.2 Add Dependencies to `mix.exs`
```elixir
defp deps do
  [
    {:phoenix, "~> 1.8"},
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_html, "~> 4.0"},
    {:phoenix_live_reload, "~> 1.5", only: :dev},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},
    {:jason, "~> 1.2"},
    {:bandit, "~> 1.0"},
    {:bcrypt_elixir, "~> 3.0"},
    {:yaml_elixir, "~> 2.11"},
    {:ymlr, "~> 5.0"},
  ]
end
```

### 1.3 Configure Tailwind CSS 4
- Set up Tailwind CSS 4 with `@theme` directive (CSS-first config)
- Reference Tailwind Plus license files at `~/gitclone/tailwind-ui-tailwind-plus/tailwindplus/` for application-ui components
- Configure `assets/css/app.css` with Tailwind imports
- Set up esbuild for JS bundling in `config/config.exs`

### 1.4 Install npm Dependencies
- `cd assets && npm install`
- Add to `assets/package.json`: `@xterm/xterm`, `@xterm/addon-fit`, `@xterm/addon-web-links`

### 1.5 Application Configuration (`config/`)

**config/config.exs** — all application-level defaults:
```elixir
config :remote_code_agents,
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
  fifo_dir: "/tmp/remote-code-agents",
  tmux_path: nil,
  tmux_socket: nil,
  output_coalesce_ms: 3,
  output_coalesce_max_bytes: 32_768,
  auth_session_ttl_days: 30
```

**config/dev.exs** — bind to localhost:4000
**config/test.exs** — shorter grace period, test FIFO dir
**config/runtime.exs** — `RCA_AUTH_TOKEN` env var, endpoint config

### 1.6 Supervision Tree (`application.ex`)

Set up `Application.start/2`:
1. FIFO directory cleanup on boot: `File.rm_rf(fifo_dir)` then `File.mkdir_p(fifo_dir)`
2. Start children in order:
   - `RemoteCodeAgents.PaneRegistry` (Registry, keys: :unique)
   - `RemoteCodeAgents.PaneStreamSupervisor` (DynamicSupervisor, `max_children` from config)
   - `Phoenix.PubSub` (name: `RemoteCodeAgents.PubSub`)
   - `RemoteCodeAgents.SessionPoller` (GenServer — stub for now)
   - `RemoteCodeAgents.Config` (GenServer — stub for now)
   - `RemoteCodeAgentsWeb.RateLimitStore` (GenServer — stub for now)
   - `RemoteCodeAgentsWeb.Endpoint`

### 1.7 Endpoint Configuration

**`endpoint.ex`**:
```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [compress: true]

socket "/socket", RemoteCodeAgentsWeb.UserSocket,
  websocket: [compress: true, connect_info: [:peer_data, :x_headers]]
```

### 1.8 Router Skeleton

Set up route structure with pipeline stubs:
- `:browser` pipeline (standard Phoenix)
- `:api` pipeline (JSON)
- `:require_auth` pipeline (stub — pass-through for now)
- `:require_auth_token` pipeline (stub — pass-through for now)
- Placeholder routes for `/`, `/login`, `/settings`, `/terminal/:target`

### 1.9 Layout & Core Components

- Set up `layouts.ex` with app shell using Tailwind Plus application-ui components
- Dark theme base (terminal app aesthetic)
- Responsive shell: sidebar for desktop, bottom nav for mobile
- `core_components.ex` with shared UI primitives

### 1.10 tmux Version Check

- Create `RemoteCodeAgents.Tmux.CommandRunner` module
- Implement `run/1` and `run!/1` functions
- Socket path support (`-S` / `-L` from config)
- tmux version check on first call (cache in `:persistent_term`)
- Log error if tmux < 2.6

### 1.11 Verify Boot

- `mix deps.get && mix compile`
- `mix phx.server` starts without errors
- Placeholder page renders at `http://localhost:4000`
- Supervision tree is healthy (all children started)

## Files Created/Modified
```
lib/remote_code_agents/application.ex
lib/remote_code_agents/tmux/command_runner.ex
lib/remote_code_agents_web/endpoint.ex
lib/remote_code_agents_web/router.ex
lib/remote_code_agents_web/components/layouts.ex
lib/remote_code_agents_web/components/core_components.ex
config/config.exs
config/dev.exs
config/test.exs
config/runtime.exs
assets/package.json
assets/css/app.css
mix.exs
```

## Exit Criteria
- App boots cleanly with `mix phx.server`
- Supervision tree starts all children
- `CommandRunner.run(["list-sessions"])` returns `{:ok, _}` or `{:error, _}` (tmux reachable)
- Tailwind CSS 4 + Tailwind Plus styles rendering
- xterm.js npm packages installed
- Placeholder page at `/` renders with the app shell layout
