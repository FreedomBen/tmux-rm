# Phase 6: Authentication & Remote Access

## Goal
Implement username+password authentication with bcrypt, optional static token fallback, session cookies for web, bearer tokens for API/Channel, rate limiting, and the login page. After this phase, the app can be safely exposed beyond localhost.

**Scope**: This is a **single-user system** by design. One username+password pair is stored in a credentials file. There is no user management, no roles, no authorization layer — any authenticated user has full access to all sessions, panes, and settings. This matches the intended use case: a single developer managing their own tmux sessions remotely.

## Dependencies
- Phase 5 complete (terminal view working)
- `Plug.Crypto` (included with Phoenix — no additional dependency)

## Steps

### 6.1 Auth Module

**`lib/tmux_rm/auth.ex`**:

- Credentials file: `~/.config/tmux_rm/credentials` (format: `username:pbkdf2_hash`, single line — this is a single-user system by design)
- `verify_credentials(username, password)` → `:ok` or `:error`
  - Check `RCA_AUTH_TOKEN` first (via `Application.get_env(:tmux_rm, :auth_token)`): if set and password matches (constant-time via `Plug.Crypto.secure_compare/2`), return `:ok`
  - Otherwise: read credentials file, compare username. If no match, perform a dummy `Plug.Crypto.verify_pass` call (timing attack mitigation), return `:error`. If match, verify via `Plug.Crypto.verify_pass(password, hash)`.
- **Password hashing**: Uses `Plug.Crypto.hash_pwd_salt/2` (PBKDF2-based, pure Elixir — no NIF/C compiler required). Simpler build pipeline than bcrypt, and sufficient security for a single-user system.
- `auth_enabled?/0` → `true` if credentials file exists or `auth_token` is configured
- `read_credentials/0` → `{:ok, {username, hash}}` or `{:error, :not_found}`
- `write_credentials(username, password)` → writes `username:bcrypt_hash` to credentials file. Sets file permissions to `0o600` (owner read/write only) via `File.chmod/2`. Creates parent directory with `0o700` if needed.

### 6.2 Mix Tasks

**`lib/mix/tasks/rca.setup.ex`** — `mix rca.setup`:
1. Prompt for username (pre-filled with `whoami`)
2. Prompt for password (with confirmation)
3. Hash via `Plug.Crypto.hash_pwd_salt/1`
4. Write to credentials file
5. Create parent directory if needed

**`lib/mix/tasks/rca.change_password.ex`** — `mix rca.change_password`:
1. Prompt for current password (verify against stored hash)
2. Prompt for new password (with confirmation)
3. Write updated credentials

### 6.3 Login Page (Web)

**`lib/tmux_rm_web/live/auth_live.ex`**:
- Username + password form
- On submit: call `Auth.verify_credentials/2`
- On success: set signed session cookie with `authenticated_at` timestamp, redirect to `/`
- On failure: flash error "Invalid username or password"
- If already authenticated: redirect to `/`

**`lib/tmux_rm_web/live/auth_live.html.heex`**:
- Clean login form using Tailwind Plus form components
- Dark theme consistent with app
- Mobile-friendly

### 6.4 Auth Hook (LiveView)

**`lib/tmux_rm_web/live/auth_hook.ex`**:
- `on_mount` hook checked on every LiveView mount (including reconnects)
- Read `authenticated_at` from session
- Compare against `auth_session_ttl_days` (default 30 days, `nil` = never expire)
- If missing or expired: redirect to `/login` with flash message
- If auth not enabled (`Auth.auth_enabled?/0` returns false): pass through (localhost mode)

### 6.5 RequireAuth Plug (HTTP)

**`lib/tmux_rm_web/plugs/require_auth.ex`**:
- Checks session cookie exists
- Redirects to `/login` if missing
- No-op if auth not enabled (localhost mode)
- Does NOT check TTL (that's AuthHook's job on LiveView mount)

### 6.6 RequireAuthToken Plug (REST API)

**`lib/tmux_rm_web/plugs/require_auth_token.ex`**:
- Reads bearer token from `Authorization: Bearer <token>` header
- Verifies via `Phoenix.Token.verify/4` with configurable max_age
- Returns 401 `{"error": "unauthorized"}` on failure
- No-op if auth not enabled

### 6.7 Auth Controller (REST API)

**`lib/tmux_rm_web/controllers/auth_controller.ex`**:

- `POST /api/login` — accepts `{"username": "...", "password": "..."}`:
  - Rate limited (via RateLimit plug, key: `:login`)
  - Verify credentials via `Auth.verify_credentials/2`
  - On success: generate `Phoenix.Token.sign/4` bearer token with `max_age: 7 * 86_400` (7 days), return `{"token": "...", "expires_in": 604800}`
  - On failure: 401 `{"error": "invalid_credentials"}`

**Token lifecycle for native clients**: Tokens expire after 7 days (configurable via `auth_token_max_age` config). Native clients should store credentials securely and handle 401 responses by transparently re-authenticating via `POST /api/login`. No refresh token endpoint is needed — this is a single-user system where automatic re-auth is simpler and equally secure.

- `DELETE /logout` — clears session cookie, redirects to `/login`

### 6.8 Rate Limiting

**`lib/tmux_rm_web/rate_limit_store.ex`** — GenServer:
- Owns ETS table (`:set`, `:public`, `read_concurrency: true`)
- Key: `{ip, endpoint_key, window_start}` → count
- `check/2` — increment counter, return `:ok` or `{:error, :rate_limited, retry_after}`
- Window: truncated to current minute (`System.system_time(:second) |> div(60)`)
- Periodic cleanup: every 5 minutes, sweep entries older than 2 minutes
- **Max table size**: If ETS table exceeds 100,000 entries (indicating a distributed attack), flush the entire table and log a warning. This prevents unbounded memory growth.

**`lib/tmux_rm_web/plugs/rate_limit.ex`** — Plug:
- Configured per-route: `plug RateLimit, key: :login` or `key: :session_create`
- Reads limits from config: `rate_limits: %{login: {5, 60}, websocket: {10, 60}, session_create: {10, 60}}`
- On exceed: 429 with `{"error": "rate_limited", "retry_after": seconds}` and `Retry-After` header
- Rate limiting is always active (even in localhost mode) to protect against accidental runaway clients or scripts

### 6.9 UserSocket (Update Existing)

**`lib/tmux_rm_web/channels/user_socket.ex`** — update the stub created in Phase 5:
- Replace pass-through `connect/3` with: check per-IP WebSocket rate limit, verify bearer token via `Phoenix.Token.verify/4`
- IP extracted from `connect_info: [:peer_data, :x_headers]`
- Return `{:ok, socket}` or `:error`
- No-op token check if auth not enabled

### 6.10 Router Updates

```elixir
# Unauthenticated
scope "/", TmuxRmWeb do
  pipe_through :browser
  live_session :unauthenticated do
    live "/login", AuthLive
  end
end

# Authenticated (web)
scope "/", TmuxRmWeb do
  pipe_through [:browser, :require_auth]
  delete "/logout", AuthController, :logout
  live_session :authenticated, on_mount: [TmuxRmWeb.AuthHook] do
    live "/", SessionListLive
    live "/terminal/:target", TerminalLive
    live "/settings", SettingsLive
    # ... more routes later
  end
end

# API - public
scope "/api", TmuxRmWeb do
  pipe_through :api
  post "/login", AuthController, :login
end

# API - authenticated
scope "/api", TmuxRmWeb do
  pipe_through [:api, :require_auth_token]
  # ... session, config routes added in later phases
end

# Health check - no auth
get "/healthz", HealthController, :show
```

### 6.11 Logging

Key log events for auth:
- `:info` — Login success (username, IP — never log passwords)
- `:info` — Login failure (username, IP)
- `:info` — Auth mode on startup (bcrypt credentials / token / disabled)
- `:warning` — Rate limit exceeded (IP, endpoint key)
- `:warning` — Rate limit table flushed (exceeded 100K entries)
- `:warning` — Listening on 0.0.0.0 with no auth configured

### 6.12 Startup Warning

In `application.ex`: if the endpoint is bound to `0.0.0.0` and `Auth.auth_enabled?/0` is false, log a warning:
"WARNING: Listening on 0.0.0.0 with no authentication configured. Set up auth via `mix rca.setup` or set RCA_AUTH_TOKEN."

### 6.13 Tests

- Auth module: test credential verification (pbkdf2, token fallback, timing-safe comparison)
- Auth plug: test redirect on missing session
- Rate limiting: test limit enforcement, window rollover, cleanup
- Login page: test form submission, success redirect, failure flash
- API login: test token generation, 401 on bad credentials, rate limiting

## Files Created/Modified
```
lib/tmux_rm/auth.ex
lib/mix/tasks/rca.setup.ex
lib/mix/tasks/rca.change_password.ex
lib/tmux_rm_web/live/auth_live.ex
lib/tmux_rm_web/live/auth_live.html.heex
lib/tmux_rm_web/live/auth_hook.ex
lib/tmux_rm_web/plugs/require_auth.ex
lib/tmux_rm_web/plugs/require_auth_token.ex
lib/tmux_rm_web/plugs/rate_limit.ex
lib/tmux_rm_web/rate_limit_store.ex
lib/tmux_rm_web/controllers/auth_controller.ex
lib/tmux_rm_web/channels/user_socket.ex
lib/tmux_rm_web/router.ex (update)
lib/tmux_rm/application.ex (startup warning)
test/tmux_rm/auth_test.exs
test/tmux_rm_web/plugs/rate_limit_test.exs
test/tmux_rm_web/live/auth_live_test.exs
```

## Exit Criteria
- `mix rca.setup` creates credentials file with bcrypt-hashed password
- `/login` page renders, validates credentials, sets session cookie
- Authenticated users access `/` and `/terminal/:target`
- Unauthenticated users redirected to `/login`
- `POST /api/login` returns bearer token on success, 401 on failure
- Rate limiting blocks excess login attempts (429 response)
- Session TTL enforced (expired sessions redirect to login)
- `RCA_AUTH_TOKEN` env var works as password fallback
- Localhost mode: auth disabled, all pages accessible without login
- Startup warning logged when bound to 0.0.0.0 without auth

## Checklist
- [ ] 6.1 Auth Module
- [ ] 6.2 Mix Tasks
- [ ] 6.3 Login Page (Web)
- [ ] 6.4 Auth Hook (LiveView)
- [ ] 6.5 RequireAuth Plug (HTTP)
- [ ] 6.6 RequireAuthToken Plug (REST API)
- [ ] 6.7 Auth Controller (REST API)
- [ ] 6.8 Rate Limiting
- [ ] 6.9 UserSocket (Update Existing)
- [ ] 6.10 Router Updates
- [ ] 6.11 Logging
- [ ] 6.12 Startup Warning
- [ ] 6.13 Tests
