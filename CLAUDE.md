# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

termigate is a Phoenix LiveView web app that provides browser-based access to tmux sessions with real-time terminal streaming. The Elixir server lives in `server/`.

## Common Commands

All commands run from `server/`:

```bash
cd server

# Setup
mix setup              # Install deps + setup assets

# Development
mix phx.server         # Start dev server at localhost:8888

# Testing
mix test               # Run all tests
mix test test/path_to_test.exs           # Run single test file
mix test test/path_to_test.exs:42        # Run test at specific line

# Pre-commit (compile warnings-as-errors + deps check + format + test)
mix precommit

# Formatting
mix format

# Assets
mix assets.build       # Build CSS/JS (Tailwind + esbuild)
```

Frontend assets use npm (`server/assets/package.json`).

## Architecture

**No database.** tmux is the source of truth; config is YAML; user prefs are in localStorage.

### Core OTP Processes

- **PaneStream** (GenServer) — one per active pane. Bidirectional bridge between tmux pane and browser viewers. Streams output via `tmux pipe-pane` + FIFO, sends input via `tmux send-keys`. Registered in a dual-key Registry (`{:pane, target}` and `{:pane_id, pane_id}`).
- **PaneStreamSupervisor** (DynamicSupervisor) — lifecycle management for PaneStreams
- **TmuxManager** — stateless module for tmux operations (list/create/kill sessions). Broadcasts `{:sessions_changed}` on PubSub topic "sessions".
- **Config** (GenServer) — reads/watches YAML config file, broadcasts changes
- **SessionPoller / LayoutPoller** — poll tmux state for changes

### Web Layer (`lib/termigate_web/`)

- **LiveViews:** `auth_live`, `session_list_live`, `terminal_live`, `multi_pane_live`, `settings_live`, `setup_live`
- **Channels:** `terminal_channel`, `session_channel` (for native app support)
- **Plugs:** `require_auth`, `require_auth_token`, `rate_limit`

### Frontend (`server/assets/`)

- xterm.js 5.x for terminal rendering
- `js/hooks/terminal_hook.js` — xterm.js ↔ LiveView integration
- Tailwind CSS 4

### Auth

Dual auth: username/password (bcrypt) and token-based (`TERMIGATE_AUTH_TOKEN` env var).

## Naming

- User-facing: `termigate`
- Elixir module/mix: `Termigate` / `termigate`
- Session names must match `^[a-zA-Z0-9_-]+$`

## Key Documentation

- `APPLICATION_DESIGN.md` — comprehensive architecture spec
- `TECH_STACK.md` — technology decisions
- `implementation-docs/` — phase-based implementation docs
