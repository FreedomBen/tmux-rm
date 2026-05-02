# termigate

Connect to your tmux session through your browser!

Termigate gives you browser-based access to tmux sessions with real-time terminal streaming. Built with Elixir, Phoenix LiveView, and xterm.js.

<p align="center">
  <img src="server/priv/static/images/termigate-logo.png" alt="termigate logo" width="200">
</p>

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

Then open [http://localhost:8888](http://localhost:8888). On first launch you'll be guided through initial setup (username/password).

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

### Container (Podman / Docker)

```bash
# Build
podman build --format docker -t termigate -f Containerfile .

# Run with container-local tmux
podman run -d -p 8888:8888 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  termigate
```

> **Note (rootless podman on Linux):** with the default pasta networking,
> the published port listens on `0.0.0.0` (IPv4) only. `localhost` resolves
> to `::1` first on most distributions, so `curl http://localhost:8888/`
> may fail with "connection reset by peer". Use `http://127.0.0.1:8888/`
> instead.

#### Origin check / PHX_HOST

By default the prod release sets `check_origin: false` whenever `PHX_HOST`
is unset, so the container is reachable from any browser the moment it
starts. Once you decide on the host/IP you'll actually visit, set
`PHX_HOST` to that value to turn the standard origin check back on.
Override explicitly with `TERMIGATE_CHECK_ORIGIN=false`, `=true`,
`=conn`, or a comma-separated list of allowed origins.

#### HTTPS / force_ssl

The default container speaks plain HTTP. Front it with a TLS terminator
(nginx, Caddy, Traefik, …) when serving over the public Internet.

To bake HTTPS-only redirects directly into the release (HSTS + 301 to
`https://`), build with `TERMIGATE_FORCE_SSL=true`:

```bash
TERMIGATE_FORCE_SSL=true podman build --format docker -t termigate -f Containerfile .
```

This is a build-time setting because Phoenix reads `:force_ssl` at
compile time. Loopback (`localhost`, `127.0.0.1`) and the Android
emulator's host alias (`10.0.2.2`) are left in the exclude list so local
clients keep working.

#### Using host tmux sessions

To access tmux sessions running on the host, mount the host's tmux socket
directory into the container and set `TERMIGATE_TMUX_SOCKET` to point at it.

1. Find your tmux socket directory — it's typically `/tmp/tmux-<UID>/`:

   ```bash
   echo "/tmp/tmux-$(id -u)"
   ```

2. Run the container with the socket mounted:

   ```bash
   podman run -d -p 8888:8888 \
     -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
     -e TERMIGATE_TMUX_SOCKET=/tmp/tmux-host/default \
     -v "/tmp/tmux-$(id -u)":/tmp/tmux-host \
     --user "$(id -u):$(id -g)" \
     termigate
   ```

   The `--user` flag ensures the container process runs as your UID/GID so it
   has permission to read/write the tmux socket. The socket is mounted at
   `/tmp/tmux-host/default` inside the container.

#### Docker

The same commands work with `docker` in place of `podman`:

```bash
docker build -t termigate -f Containerfile .
docker run -d -p 8888:8888 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  termigate
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

See [APPLICATION_DESIGN.md](docs/APPLICATION_DESIGN.md) and [TECH_STACK.md](docs/TECH_STACK.md) for full details.

## License

Licensed under the GNU Affero General Public License v3.0 (AGPLv3). See [LICENSE](LICENSE) for the full text.
