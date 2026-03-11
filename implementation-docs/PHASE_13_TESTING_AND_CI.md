# Phase 13: Testing & CI/CD

## Goal
Set up CI/CD via GitHub Actions and consolidate test coverage across all layers. **Tests are written incrementally in each phase** (every phase has a "Tests" section and exit criteria requiring passing tests). This phase does NOT introduce first-time test writing — it sets up CI, fills any coverage gaps, and formalizes the test infrastructure.

## Dependencies
- All previous phases complete (tests written incrementally per phase)

## Steps

### 13.1 Test Infrastructure

**Note**: Core test infrastructure (Mox setup, `MockCommandRunner`, `TmuxHelpers`, `test_helper.exs`) is established in **Phase 1** (step 1.11) so that all subsequent phases can write tests immediately. This phase extends and formalizes that foundation.

**Test configuration** (`server/config/test.exs`) — extend what Phase 1 set up:
```elixir
config :tmux_rm,
  pane_stream_grace_period: 100,    # Short for fast tests
  fifo_dir: "/tmp/tmux-rm-test",
  session_poll_interval: 500,       # Faster polling in tests
  config_poll_interval: 500,
  output_coalesce_ms: 0             # Disable coalescing in tests for determinism
```

### 13.2 Unit Tests (No tmux Required)

These run with mocked CommandRunner:

| Module | Test File | Key Cases |
|--------|-----------|-----------|
| `TmuxManager` | `tmux_manager_test.exs` | Parse list-sessions/panes, name validation, error handling |
| `RingBuffer` | `ring_buffer_test.exs` | Append, read, overflow, size, empty |
| `Auth` | `auth_test.exs` | Bcrypt verify, token fallback, timing-safe comparison |
| `Config` | `config_test.exs` | Load/save YAML, mtime polling, malformed file, CRUD ops |
| `CommandRunner` | `command_runner_test.exs` | Socket args, version check, error formatting |

### 13.3 Integration Tests (Require tmux)

Tagged with `@tag :tmux` — skipped in CI environments without tmux:

| Module | Test File | Key Cases |
|--------|-----------|-----------|
| `PaneStream` | `pane_stream_test.exs` | Subscribe, output streaming, send_keys, grace period, pane death, Port crash recovery, multiple viewers |
| `TmuxManager (integration)` | `tmux_manager_integration_test.exs` | Real session create/list/kill/rename with tmux |
| `SessionPoller` | `session_poller_test.exs` | Poll detects changes, PubSub broadcast |

### 13.4 LiveView Tests

Using `Phoenix.LiveViewTest`:

| LiveView | Test File | Key Cases |
|----------|-----------|-----------|
| `SessionListLive` | `session_list_live_test.exs` | Mount, session rendering, create form, kill session, empty state, error state |
| `TerminalLive` | `terminal_live_test.exs` | Mount with valid/invalid target, key_input event, pane_dead handling, PaneStream crash recovery |
| `AuthLive` | `auth_live_test.exs` | Login form, success redirect, failure flash, already-authenticated redirect |
| `SettingsLive` | `settings_live_test.exs` | Add/edit/delete quick actions, reorder, PubSub sync |
| `MultiPaneLive` | `multi_pane_live_test.exs` | Mount, multi-pane rendering, window tabs |

### 13.5 Controller Tests

| Controller | Test File | Key Cases |
|------------|-----------|-----------|
| `AuthController` | `auth_controller_test.exs` | POST /api/login (success, failure, rate limited), DELETE /logout |
| `HealthController` | `health_controller_test.exs` | 200 ok, 200 no_server, 503 not_found |
| `SessionController` | `session_controller_test.exs` | CRUD operations, validation, auth required |
| `PaneController` | `pane_controller_test.exs` | Split, delete, auth required |
| `QuickActionController` | `quick_action_controller_test.exs` | CRUD, reorder, auth required |
| `ConfigController` | `config_controller_test.exs` | GET /api/config |

### 13.6 Channel Tests

Using `Phoenix.ChannelTest`:

| Channel | Test File | Key Cases |
|---------|-----------|-----------|
| `TerminalChannel` | `terminal_channel_test.exs` | Join, input/output, pane death, reconnect |
| `SessionChannel` | `session_channel_test.exs` | Join, session updates, diffing |

### 13.7 Plug Tests

| Plug | Test File | Key Cases |
|------|-----------|-----------|
| `RequireAuth` | `require_auth_test.exs` | Redirect when no session, pass-through when authenticated, no-op in localhost mode |
| `RequireAuthToken` | `require_auth_token_test.exs` | 401 on missing/invalid token, pass-through on valid |
| `RateLimit` | `rate_limit_test.exs` | Under limit, at limit, over limit, window rollover |

### 13.8 E2E Tests (Optional — Wallaby)

If Wallaby is set up with Chromedriver:
- Full flow: login → session list → create session → open terminal → type command → see output
- Mobile viewport: virtual toolbar interaction
- Multi-pane: open multi-pane view, verify all panes render

### 13.9 GitHub Actions CI

**`.github/workflows/ci.yml`**:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Install tmux
        run: sudo apt-get install -y tmux

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '27'

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            server/deps
            server/_build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}

      - name: Install Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install dependencies
        run: cd server && mix deps.get

      - name: Install npm deps
        run: cd server/assets && npm ci

      - name: Check formatting
        run: cd server && mix format --check-formatted

      - name: Compile (warnings as errors)
        run: cd server && mix compile --warnings-as-errors

      - name: Build assets
        run: cd server && mix assets.deploy
        env:
          MIX_ENV: prod

      - name: Run tests
        run: cd server && mix test
        env:
          MIX_ENV: test

  release:
    needs: test
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '27'

      - name: Build release
        run: |
          cd server
          mix deps.get --only prod
          MIX_ENV=prod mix assets.deploy
          MIX_ENV=prod mix release
        env:
          MIX_ENV: prod
```

### 13.10 Test Tags and Exclusions

```elixir
# server/test/test_helper.exs
ExUnit.start(exclude: [:skip])

# Exclude tmux tests if tmux not installed
unless System.find_executable("tmux") do
  ExUnit.configure(exclude: [:tmux])
end
```

### 13.11 Code Quality

- `mix format` — enforce consistent formatting
- `mix compile --warnings-as-errors` — no warnings in CI
- Consider adding `credo` for static analysis (optional)
- Consider adding `dialyxir` for type checking (optional)

## Files Created/Modified
```
.github/workflows/ci.yml
server/test/test_helper.exs
server/test/support/tmux_helpers.ex
server/test/support/mocks.ex
server/test/tmux_rm/ring_buffer_test.exs
server/test/tmux_rm/tmux_manager_test.exs
server/test/tmux_rm/tmux_manager_integration_test.exs
server/test/tmux_rm/pane_stream_test.exs
server/test/tmux_rm/auth_test.exs
server/test/tmux_rm/config_test.exs
server/test/tmux_rm/session_poller_test.exs
server/test/tmux_rm_web/live/session_list_live_test.exs
server/test/tmux_rm_web/live/terminal_live_test.exs
server/test/tmux_rm_web/live/auth_live_test.exs
server/test/tmux_rm_web/live/settings_live_test.exs
server/test/tmux_rm_web/live/multi_pane_live_test.exs
server/test/tmux_rm_web/channels/terminal_channel_test.exs
server/test/tmux_rm_web/channels/session_channel_test.exs
server/test/tmux_rm_web/controllers/auth_controller_test.exs
server/test/tmux_rm_web/controllers/health_controller_test.exs
server/test/tmux_rm_web/controllers/session_controller_test.exs
server/test/tmux_rm_web/controllers/pane_controller_test.exs
server/test/tmux_rm_web/controllers/quick_action_controller_test.exs
server/test/tmux_rm_web/plugs/require_auth_test.exs
server/test/tmux_rm_web/plugs/require_auth_token_test.exs
server/test/tmux_rm_web/plugs/rate_limit_test.exs
```

## Exit Criteria
- All unit tests pass without tmux installed
- All integration tests pass with tmux installed
- All LiveView tests pass
- All controller/channel tests pass
- GitHub Actions CI runs on push/PR, all checks green
- `mix format --check-formatted` passes
- `mix compile --warnings-as-errors` passes
- Release builds successfully in CI on tags

## Checklist
- [x] 13.1 Test Infrastructure
- [x] 13.2 Unit Tests (No tmux Required)
- [x] 13.3 Integration Tests (Require tmux)
- [x] 13.4 LiveView Tests
- [x] 13.5 Controller Tests
- [x] 13.6 Channel Tests
- [x] 13.7 Plug Tests
- [ ] 13.8 E2E Tests (Optional)
- [x] 13.9 GitHub Actions CI
- [x] 13.10 Test Tags and Exclusions
- [x] 13.11 Code Quality
