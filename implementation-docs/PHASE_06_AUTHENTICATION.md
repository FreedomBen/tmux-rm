# Phase 6: Authentication & Remote Access

## Goal
Implement username+password authentication with bcrypt, optional static token fallback, session cookies for web, bearer tokens for API/Channel, rate limiting, and the login page. After this phase, the app can be safely exposed beyond localhost.

## Dependencies
- Phase 5 complete (terminal view working)
- `bcrypt_elixir` dependency (Phase 1)

## Steps

### 6.1 Auth Module

**`lib/remote_code_agents/auth.ex`**:

- Credentials file: `~/.config/remote_code_agents/credentials` (format: `username:bcrypt_hash`)
- `verify_credentials(username, password)` → `:ok` or `:error`
  - Check `RCA_AUTH_TOKEN` first (via `Application.get_env(:remote_code_agents, :auth_token)`): if set and password matches (constant-time via `Plug.Crypto.secure_compare/2`), return `:ok`
  - Otherwise: read credentials file, compare username. If no match, call `Bcrypt.no_user_verify/0` (timing attack mitigation), return `:error`. If match, verify via `Bcrypt.verify_pass/2`.
- `auth_enabled?/0` → `true` if credentials file exists or `auth_token` is configured
- `read_credentials/0` → `{:ok, {username, hash}}` or `{:error, :not_found}`
- `write_credentials(username, password)` → writes `username:bcrypt_hash` to credentials file

### 6.2 Mix Tasks

**`lib/mix/tasks/rca.setup.ex`** — `mix rca.setup`:
1. Prompt for username (pre-filled with `whoami`)
2. Prompt for password (with confirmation)
3. Hash via `Bcrypt.hash_pwd_salt/1`
4. Write to credentials file
5. Create parent directory if needed

**`lib/mix/tasks/rca.change_password.ex`** — `mix rca.change_password`:
1. Prompt for current password (verify against stored hash)
2. Prompt for new password (with confirmation)
3. Write updated credentials

### 6.3 Login Page (Web)

**`lib/remote_code_agents_web/live/auth_live.ex`**:
- Username + password form
- On submit: call `Auth.verify_credentials/2`
- On success: set signed session cookie with `authenticated_at` timestamp, redirect to `/`
- On failure: flash error "Invalid username or password"
- If already authenticated: redirect to `/`

**`lib/remote_code_agents_web/live/auth_live.html.heex`**:
- Clean login form using Tailwind Plus form components
- Dark theme consistent with app
- Mobile-friendly

### 6.4 Auth Hook (LiveView)

**`lib/remote_code_agents_web/live/auth_hook.ex`**:
- `on_mount` hook checked on every LiveView mount (including reconnects)
- Read `authenticated_at` from session
- Compare against `auth_session_ttl_days` (default 30 days, `nil` = never expire)
- If missing or expired: redirect to `/login` with flash message
- If auth not enabled (`Auth.auth_enabled?/0` returns false): pass through (localhost mode)

### 6.5 RequireAuth Plug (HTTP)

**`lib/remote_code_agents_web/plugs/require_auth.ex`**:
- Checks session cookie exists
- Redirects to `/login` if missing
- No-op if auth not enabled (localhost mode)
- Does NOT check TTL (that's AuthHook's job on LiveView mount)

### 6.6 RequireAuthToken Plug (REST API)

**`lib/remote_code_agents_web/plugs/require_auth_token.ex`**:
- Reads bearer token from `Authorization: Bearer <token>` header
- Verifies via `Phoenix.Token.verify/4` with configurable max_age
- Returns 401 `{"error": "unauthorized"}` on failure
- No-op if auth not enabled

### 6.7 Auth Controller (REST API)

**`lib/remote_code_agents_web/controllers/auth_controller.ex`**:

- `POST /api/login` — accepts `{"username": "...", "password": "..."}`:
  - Rate limited (via RateLimit plug, key: `:login`)
  - Verify credentials via `Auth.verify_credentials/2`
  - On success: generate `Phoenix.Token.sign/4` bearer token, return `{"token": "..."}`
  - On failure: 401 `{"error": "invalid_credentials"}`

- `DELETE /logout` — clears session cookie, redirects to `/login`

### 6.8 Rate Limiting

**`lib/remote_code_agents_web/rate_limit_store.ex`** — GenServer:
- Owns ETS table (`:set`, `:public`, `read_concurrency: true`)
- Key: `{ip, endpoint_key, window_start}` → count
- `check/2` — increment counter, return `:ok` or `{:error, :rate_limited, retry_after}`
- Window: truncated to current minute (`System.system_time(:second) |> div(60)`)
- Periodic cleanup: every 5 minutes, sweep entries older than 2 minutes

**`lib/remote_code_agents_web/plugs/rate_limit.ex`** — Plug:
- Configured per-route: `plug RateLimit, key: :login` or `key: :session_create`
- Reads limits from config: `rate_limits: %{login: {5, 60}, websocket: {10, 60}, session_create: {10, 60}}`
- On exceed: 429 with `{"error": "rate_limited", "retry_after": seconds}` and `Retry-After` header
- Skipped when auth not enabled (localhost mode)

### 6.9 UserSocket

**`lib/remote_code_agents_web/channels/user_socket.ex`**:
- `connect/3`: check per-IP WebSocket rate limit, verify bearer token via `Phoenix.Token.verify/4`
- IP extracted from `connect_info: [:peer_data, :x_headers]`
- Return `{:ok, socket}` or `:error`
- No-op token check if auth not enabled

### 6.10 Router Updates

```elixir
# Unauthenticated
scope "/", RemoteCodeAgentsWeb do
  pipe_through :browser
  live_session :unauthenticated do
    live "/login", AuthLive
  end
end

# Authenticated (web)
scope "/", RemoteCodeAgentsWeb do
  pipe_through [:browser, :require_auth]
  delete "/logout", AuthController, :logout
  live_session :authenticated, on_mount: [RemoteCodeAgentsWeb.AuthHook] do
    live "/", SessionListLive
    live "/terminal/:target", TerminalLive
    live "/settings", SettingsLive
    # ... more routes later
  end
end

# API - public
scope "/api", RemoteCodeAgentsWeb do
  pipe_through :api
  post "/login", AuthController, :login
end

# API - authenticated
scope "/api", RemoteCodeAgentsWeb do
  pipe_through [:api, :require_auth_token]
  # ... session, config routes added in later phases
end

# Health check - no auth
get "/healthz", HealthController, :show
```

### 6.11 Startup Warning

In `application.ex`: if the endpoint is bound to `0.0.0.0` and `Auth.auth_enabled?/0` is false, log a warning:
"WARNING: Listening on 0.0.0.0 with no authentication configured. Set up auth via `mix rca.setup` or set RCA_AUTH_TOKEN."

### 6.12 Tests

- Auth module: test credential verification (bcrypt, token fallback, timing-safe comparison)
- Auth plug: test redirect on missing session
- Rate limiting: test limit enforcement, window rollover, cleanup
- Login page: test form submission, success redirect, failure flash
- API login: test token generation, 401 on bad credentials, rate limiting

## Files Created/Modified
```
lib/remote_code_agents/auth.ex
lib/mix/tasks/rca.setup.ex
lib/mix/tasks/rca.change_password.ex
lib/remote_code_agents_web/live/auth_live.ex
lib/remote_code_agents_web/live/auth_live.html.heex
lib/remote_code_agents_web/live/auth_hook.ex
lib/remote_code_agents_web/plugs/require_auth.ex
lib/remote_code_agents_web/plugs/require_auth_token.ex
lib/remote_code_agents_web/plugs/rate_limit.ex
lib/remote_code_agents_web/rate_limit_store.ex
lib/remote_code_agents_web/controllers/auth_controller.ex
lib/remote_code_agents_web/channels/user_socket.ex
lib/remote_code_agents_web/router.ex (update)
lib/remote_code_agents/application.ex (startup warning)
test/remote_code_agents/auth_test.exs
test/remote_code_agents_web/plugs/rate_limit_test.exs
test/remote_code_agents_web/live/auth_live_test.exs
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
