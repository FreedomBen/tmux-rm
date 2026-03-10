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
    {:mox, "~> 1.0", only: :test},
    {:corsica, "~> 2.0"},
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
  auth_session_ttl_days: 30,
  auth_token_max_age: 604_800
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
   - `RemoteCodeAgents.LayoutPollerSupervisor` (DynamicSupervisor — used by Phase 12 for layout pollers, started early so the supervision tree doesn't need modification later)
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

### 1.10 CommandRunner Behaviour & Implementation

**`lib/remote_code_agents/tmux/command_runner_behaviour.ex`** — behaviour for testability:
```elixir
defmodule RemoteCodeAgents.Tmux.CommandRunnerBehaviour do
  @doc "Run a tmux command with the given arguments. Returns stdout on success."
  @callback run(args :: [String.t()]) :: {:ok, String.t()} | {:error, {String.t(), non_neg_integer()}}

  @doc "Run a tmux command. Raises on failure."
  @callback run!(args :: [String.t()]) :: String.t()
end
```

**`lib/remote_code_agents/tmux/command_runner.ex`** — real implementation:
- Implements `CommandRunnerBehaviour`
- `run/1` — builds full command with socket args, calls `System.cmd/3`, returns `{:ok, stdout}` or `{:error, {stderr, exit_code}}`
- `run!/1` — calls `run/1`, raises on error
- Socket path support (`-S` / `-L` from config)
- tmux version check on first call (cache in `:persistent_term`)
- Log error if tmux < 2.6

**Application config** — allow swapping the implementation for tests:
```elixir
# config/config.exs
config :remote_code_agents, :command_runner, RemoteCodeAgents.Tmux.CommandRunner

# config/test.exs
config :remote_code_agents, :command_runner, RemoteCodeAgents.MockCommandRunner
```

All modules that call CommandRunner should use:
```elixir
defp command_runner, do: Application.get_env(:remote_code_agents, :command_runner)
```

### 1.11 Test Infrastructure

Set up test infrastructure early so all subsequent phases can write tests immediately:

**`test/test_helper.exs`**:
```elixir
ExUnit.start(exclude: [:skip])

# Exclude tmux integration tests if tmux not installed
unless System.find_executable("tmux") do
  ExUnit.configure(exclude: [:tmux])
end
```

**`test/support/mocks.ex`**:
```elixir
Mox.defmock(RemoteCodeAgents.MockCommandRunner, for: RemoteCodeAgents.Tmux.CommandRunnerBehaviour)
```

**`test/support/tmux_helpers.ex`**:
```elixir
defmodule RemoteCodeAgents.TmuxHelpers do
  def create_test_session(name \\ nil) do
    name = name || "test-#{:rand.uniform(100_000)}"
    {_, 0} = System.cmd("tmux", ["new-session", "-d", "-s", name])
    name
  end

  def destroy_test_session(name) do
    System.cmd("tmux", ["kill-session", "-t", name])
  end

  def setup_tmux(_context) do
    name = create_test_session()
    on_exit(fn -> destroy_test_session(name) end)
    %{session: name}
  end
end
```

Ensure `test/support` is compiled in test env via `mix.exs`:
```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

### 1.12 Logging

Add `require Logger` to all modules. Key log events for this phase:
- `:info` — Application startup: bind address, tmux version, auth mode
- `:info` — tmux version check result
- `:warning` — tmux version < 2.6
- `:warning` — tmux binary not found
- `:debug` — Individual tmux commands executed by CommandRunner (args + exit code)

### 1.13 Verify Boot

- `mix deps.get && mix compile`
- `mix phx.server` starts without errors
- Placeholder page renders at `http://localhost:4000`
- Supervision tree is healthy (all children started)

## Files Created/Modified
```
lib/remote_code_agents/application.ex
lib/remote_code_agents/tmux/command_runner_behaviour.ex
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
test/test_helper.exs
test/support/mocks.ex
test/support/tmux_helpers.ex
```

## Exit Criteria
- App boots cleanly with `mix phx.server`
- Supervision tree starts all children
- `CommandRunner.run(["list-sessions"])` returns `{:ok, _}` or `{:error, _}` (tmux reachable)
- Tailwind CSS 4 + Tailwind Plus styles rendering
- xterm.js npm packages installed
- Placeholder page at `/` renders with the app shell layout
