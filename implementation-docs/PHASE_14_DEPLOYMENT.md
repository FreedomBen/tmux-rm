# Phase 14: Deployment & Release

## Goal
Prepare the application for production deployment: Mix release configuration, systemd service file, Docker support, runtime configuration, and deployment documentation. After this phase, the app can be deployed as a single binary with zero infrastructure dependencies beyond tmux.

## Dependencies
- All previous phases complete

## Steps

### 14.1 Mix Release Configuration

**`mix.exs`** release config:
```elixir
def project do
  [
    # ...
    releases: [
      remote_code_agents: [
        include_erts: true  # Bundle Erlang runtime
        # Cookie is set via RELEASE_COOKIE env var at runtime, not hardcoded
      ]
    ]
  ]
end
```

### 14.2 Runtime Configuration

**`config/runtime.exs`** — all environment-dependent config:
```elixir
import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE not set"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")
  bind_ip = if System.get_env("PHX_BIND") == "0.0.0.0", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

  config :remote_code_agents, RemoteCodeAgentsWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: bind_ip, port: port],
    secret_key_base: secret_key_base,
    server: true

  # Optional auth token for headless setups
  config :remote_code_agents,
    auth_token: System.get_env("RCA_AUTH_TOKEN")

  # Optional tmux socket
  if socket = System.get_env("RCA_TMUX_SOCKET") do
    config :remote_code_agents, tmux_socket: socket
  end
end
```

### 14.3 Asset Build

Production asset pipeline:
```bash
# In CI or build script:
cd assets && npm ci
cd ..
MIX_ENV=prod mix assets.deploy  # Builds + digests JS/CSS
```

Ensure `esbuild` and `tailwind` are configured for production minification.

### 14.4 Build Script

**`bin/build-release.sh`**:
```bash
#!/bin/bash
set -e

export MIX_ENV=prod

echo "==> Installing dependencies"
mix deps.get --only prod

echo "==> Compiling"
mix compile

echo "==> Building assets"
cd assets && npm ci && cd ..
mix assets.deploy

echo "==> Building release"
mix release

echo "==> Release built at _build/prod/rel/remote_code_agents/"
```

### 14.5 Systemd Service

**`deploy/tmux-rm.service`**:
```ini
[Unit]
Description=tmux-rm — Remote terminal manager
After=network.target

[Service]
Type=exec
User=ben
Group=ben
WorkingDirectory=/opt/remote_code_agents
Environment=HOME=/home/ben
Environment=PORT=4000
Environment=PHX_HOST=localhost
Environment=SECRET_KEY_BASE=generate-a-secret-key-base-here
# Uncomment for remote access:
# Environment=PHX_BIND=0.0.0.0
# Environment=RCA_AUTH_TOKEN=your-secure-token
ExecStart=/opt/remote_code_agents/bin/remote_code_agents start
ExecStop=/opt/remote_code_agents/bin/remote_code_agents stop
Restart=on-failure
RestartSec=5
# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/tmp/remote-code-agents /home/ben/.config/remote_code_agents
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
```

Installation:
```bash
sudo cp deploy/tmux-rm.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable tmux-rm
sudo systemctl start tmux-rm
```

### 14.6 Docker Support

**`Dockerfile`**:
```dockerfile
# Build stage
FROM elixir:1.17-slim AS build

RUN apt-get update && apt-get install -y build-essential git nodejs npm && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY assets/package.json assets/package-lock.json ./assets/
RUN cd assets && npm ci

COPY . .
RUN mix assets.deploy && mix release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends tmux locales && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

COPY --from=build /app/_build/prod/rel/remote_code_agents /app

EXPOSE 4000

CMD ["/app/bin/remote_code_agents", "start"]
```

**Docker deployment modes**:

The Dockerfile installs tmux inside the container, so the default mode runs tmux sessions *inside* the container. To connect to **host** tmux sessions instead, mount the host's tmux socket and set `RCA_TMUX_SOCKET`.

**UID/GID mapping for host tmux access**: The container must run as the same UID as the host user who owns the tmux socket. Use `--user $(id -u):$(id -g)` when running the container, or set `user:` in docker-compose. The tmux socket is typically at `/tmp/tmux-{UID}/default` and is only readable by the owning user.

**`docker-compose.yml`** (optional, for easy testing):
```yaml
services:
  tmux-rm:
    build: .
    ports:
      - "4000:4000"
    environment:
      - SECRET_KEY_BASE=generate-me
      - PORT=4000
      - PHX_HOST=localhost
      # Uncomment for host tmux access:
      # - RCA_TMUX_SOCKET=/tmp/tmux-host/default
    # user: "1000:1000"  # Must match host UID:GID for tmux socket access
    # volumes:
      # Uncomment for host tmux access (replace 1000 with your UID):
      # - /tmp/tmux-1000:/tmp/tmux-host
```

### 14.7 Configuration Precedence

When the same setting can be specified in multiple places, the precedence order is:

1. **Environment variables** (highest priority) — e.g., `RCA_AUTH_TOKEN`, `PORT`, `PHX_HOST`
2. **YAML config file** (`~/.config/remote_code_agents/config.yaml`) — quick actions, app settings
3. **`config/runtime.exs`** compile-time defaults (lowest priority)

This is enforced in `config/runtime.exs` by only reading env vars with `||` fallbacks, and in the `Config` GenServer by merging YAML values over defaults. Environment variables always win because they're read in `runtime.exs` before the Config GenServer starts.

### 14.8 CORS Configuration

For deployments where native clients or external tools access the REST API from a different origin:

- By default, no CORS headers are set (same-origin only)
- If `RCA_CORS_ORIGIN` env var is set, add CORS headers via a Plug:
  ```elixir
  # In endpoint.ex or a dedicated plug:
  if origin = Application.get_env(:remote_code_agents, :cors_origin) do
    plug Corsica, origins: origin, allow_headers: ["authorization", "content-type"]
  end
  ```
- For single-origin deployments: `RCA_CORS_ORIGIN=https://my-app.example.com`
- For development: `RCA_CORS_ORIGIN=*`
- Add `{:corsica, "~> 2.0"}` to deps in `mix.exs` (Phase 1)

Note: WebSocket connections (LiveView and Channels) are not affected by CORS — they use the `check_origin` setting on the endpoint, which is already configured by Phoenix.

### 14.9 BEAM Distribution Safety

Ensure production release does NOT enable BEAM distribution:
- Default `mix release` config does not start EPMD or distributed Erlang
- Verify: the release should start with `--no-epmd` by default
- If remote debugging is needed, use `--remsh` over SSH, not network distribution

### 14.10 Secret Key Generation

Document how to generate `SECRET_KEY_BASE`:
```bash
mix phx.gen.secret
# Or:
openssl rand -base64 64
```

### 14.11 HTTPS Configuration Options

Document the three deployment options for remote access:

1. **Reverse proxy (nginx/Caddy)**: App stays HTTP, proxy handles TLS
2. **Phoenix direct TLS**: Configure `:https` in endpoint with cert/key paths
3. **Tailscale/WireGuard**: VPN access, no public exposure, app stays HTTP

Example configs for option 1:

**Caddy** (recommended — automatic HTTPS via Let's Encrypt):
```
tmux-rm.example.com {
  reverse_proxy localhost:4000
}
```

**nginx**:
```nginx
server {
    listen 443 ssl;
    server_name tmux-rm.example.com;

    ssl_certificate /etc/letsencrypt/live/tmux-rm.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/tmux-rm.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;  # WebSocket keep-alive (24h)
    }
}
```

Note: WebSocket support (`Upgrade`/`Connection` headers) is critical — both LiveView and Channels use WebSockets. The `proxy_read_timeout` must be long enough to keep idle WebSocket connections alive.

### 14.12 Health Check Integration

- systemd: use `ExecStartPost` with curl to `/healthz` or `Type=notify` with health checks
- Docker: `HEALTHCHECK CMD curl -f http://localhost:4000/healthz || exit 1`
- Reverse proxy: upstream health check to `/healthz`

### 14.13 Logging

- Ensure meaningful actions are logged (startup, auth events, pane stream lifecycle)
- Production log level: `:info` (configurable via `LOGGER_LEVEL` env var)
- Structured logging format for log aggregation (optional: `logger_json` dependency)
- **Key events to log** (at `:info` level):
  - Application startup (bind address, auth mode, tmux version)
  - Authentication events (login success/failure — log IP, not password)
  - PaneStream lifecycle (start, subscriber count changes, grace period, shutdown)
  - Config file changes (loaded, reloaded, malformed)
- **Warning-level events**: auth disabled on 0.0.0.0, malformed config, rate limit table flush
- **Debug-level events**: individual tmux commands (useful for troubleshooting, noisy in production)

## Files Created/Modified
```
mix.exs (release config)
config/runtime.exs (production config)
bin/build-release.sh
deploy/tmux-rm.service
Dockerfile
docker-compose.yml (optional)
.dockerignore
```

## Exit Criteria
- `MIX_ENV=prod mix release` builds a self-contained release
- Release starts with `bin/remote_code_agents start` — serves the app
- systemd service file installs and works
- Docker image builds and runs (with tmux inside container)
- Health check endpoint responds correctly in production
- `SECRET_KEY_BASE` required in prod (errors clearly if missing)
- Auth token configurable via env var
- BEAM distribution disabled in production
- App starts cleanly, logs meaningful startup info
