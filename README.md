# termigate

Browser-based access to tmux sessions with real-time terminal streaming. Built with Elixir, Phoenix LiveView, and xterm.js.

## What it does

termigate runs on a host machine and lets you attach to tmux sessions from any web browser. It streams terminal output in real-time and sends your keyboard input back to the pane — so you get a fully interactive terminal over HTTP.

- **Real-time streaming** via LiveView WebSocket and `tmux pipe-pane`
- **Multi-pane views** with resizable split layouts
- **Multiple viewers** can watch and interact with the same pane simultaneously
- **Scrollback history** captured when you attach to a pane
- **Mobile-friendly** UI — fully usable on phone browsers
- **Quick actions** — configurable one-tap buttons for common commands
- **Session management** — create, kill, split, and resize panes from the UI
- **No database** — tmux is the source of truth; config is YAML; user prefs are in localStorage

## Requirements

- Elixir 1.19+
- Node.js (for asset building)
- tmux

## Quick start

```bash
cd server
mix setup
mix phx.server
```

Then open [http://localhost:4000](http://localhost:4000). On first launch you'll be guided through initial setup (username/password).

## Auth

termigate supports two auth methods:

- **Username/password** — set up during initial setup, stored as a bcrypt hash
- **Token-based** — set the `TERMIGATE_AUTH_TOKEN` environment variable for headless/scripted access

## Configuration

Config is stored in `~/.config/termigate/config.yml` (created automatically on first run). Quick actions and other settings can be edited through the UI or by modifying the YAML file directly.

## Development

```bash
cd server

mix test                              # Run all tests
mix test test/path_to_test.exs        # Run a single test file
mix test test/path_to_test.exs:42     # Run test at specific line
mix format                            # Format code
mix precommit                         # Compile (warnings-as-errors) + deps check + format + test
mix assets.build                      # Build CSS/JS
```

## Deployment

### Mix release

```bash
bin/build-release.sh
```

The release is built to `server/_build/prod/rel/termigate/`.

### Docker

```bash
docker build -t termigate .
docker run -d -p 4000:4000 termigate
```

### systemd

A service file is provided at `deploy/termigate.service`. Copy it to `/etc/systemd/system/`, adjust the user/paths, generate a secret key base, and:

```bash
sudo systemctl enable --now termigate
```

## Architecture

The server is a Phoenix LiveView app with no database. Core OTP processes:

- **PaneStream** (GenServer) — one per active pane. Bidirectional bridge between tmux and browser viewers via `tmux pipe-pane` (output) and `tmux send-keys` (input).
- **PaneStreamSupervisor** (DynamicSupervisor) — lifecycle management for PaneStreams.
- **TmuxManager** — stateless module for tmux operations (list/create/kill sessions).
- **Config** (GenServer) — reads/watches the YAML config file, broadcasts changes.

Frontend uses xterm.js 5.x for terminal rendering, connected to LiveView via a custom hook.

See [APPLICATION_DESIGN.md](APPLICATION_DESIGN.md) and [TECH_STACK.md](TECH_STACK.md) for full details.

## License

All rights reserved.
