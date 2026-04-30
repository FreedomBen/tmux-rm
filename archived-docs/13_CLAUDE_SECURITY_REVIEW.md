# Security review

**Date:** 2026-04-30
**Scope:** `/home/ben/gitclone/termigate/server/` (Phoenix/Elixir backend; Android client and built static assets out of scope)
**Reviewer:** Claude Code

## Summary

termigate is a single-user Phoenix LiveView app that brokers tmux access to a
browser. The auth surface is intentionally small (one credential pair plus an
optional static bearer token), the tmux fan-out uses `System.cmd` with argv
lists rather than a shell, and rate limits / CSRF / signed sessions are wired
in. The biggest practical exposures are an unrate-limited browser login form
and a non-constant-time comparison on the metrics token. There are also a
handful of medium-severity hardening gaps (cookie `secure` flag, default
`check_origin: false`, log injection on usernames) that are worth tightening
before exposing termigate beyond a trusted LAN.

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 2     |
| Medium   | 4     |
| Low      | 4     |

## Findings

### [HIGH] Web `POST /login` is not rate-limited
- **Location:** `lib/termigate_web/router.ex:75-82` (web routes), compared
  against `lib/termigate_web/router.ex:48-51` (API `/api/login`).
- **Issue:** `post "/login", AuthController, :web_login` is mounted in the
  `:browser` pipeline only. The `:rate_limit_login` plug is only attached to
  the `/api/login` scope. The browser login endpoint reaches
  `Auth.verify_credentials/2` (PBKDF2 100k iterations, secure compare) with no
  IP-based throttling.
- **Impact:** An unauthenticated attacker can submit unlimited POSTs to
  `/login` from a single IP. PBKDF2 cost rate-limits the attempt rate to a few
  per second per CPU core, but there is no per-IP cap and no lockout.
  Telemetry will fire on every attempt but nothing slows or blocks the caller.
- **Fix:** Add a `:rate_limit_login` pipeline to the `POST /login` web route,
  e.g. wrap the path in its own scope:

  ```elixir
  scope "/", TermigateWeb do
    pipe_through [:browser, :rate_limit_login]
    post "/login", AuthController, :web_login
  end
  ```

  The same `RateLimitStore` already used by the API endpoint will then apply
  (current default `{5, 60}`).

### [HIGH] Non-constant-time comparison on the metrics token
- **Location:** `lib/termigate_web/controllers/metrics_controller.ex:9`.
- **Issue:** The metrics endpoint compares the bearer token with `==`:

  ```elixir
  ["Bearer " <> token] when token == metrics_token ->
  ```

  Erlang/Elixir string equality short-circuits on the first mismatching byte,
  which makes the comparison timing-distinguishable. With enough samples an
  off-path attacker can iterate the token byte by byte.
- **Impact:** A determined attacker who can hit `/metrics` directly (the route
  is unauthenticated by Phoenix's pipelines, so any reachable client can probe
  it whenever `TERMIGATE_METRICS_TOKEN` is set) can recover the metrics
  bearer. The metrics endpoint reveals VM memory, active stream counts, and
  similar information; if reused, the same token also gates whatever else the
  operator wires up next.
- **Fix:** Use `Plug.Crypto.secure_compare/2`, which the codebase already
  uses for the static auth token in `Termigate.Auth.verify_credentials/2`:

  ```elixir
  ["Bearer " <> token] ->
    if Plug.Crypto.secure_compare(token, metrics_token) do
      json(conn, collect_metrics())
    else
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  ```

### [MEDIUM] Session cookie does not set the `secure` flag
- **Location:** `lib/termigate_web/endpoint.ex:7-12` (`@session_options`).
- **Issue:** The session-cookie options set only `same_site: "Lax"`. There is
  no `secure: true` or environment-conditional secure flag. `Plug.Session`
  defaults `http_only: true` (good) but leaves `secure: false`. Even when
  `TERMIGATE_FORCE_SSL=true` is set at build time, the session cookie itself
  is still permitted over plain HTTP.
- **Impact:** A passive network observer on a non-TLS leg (e.g. between
  Caddy/Nginx and termigate, or any direct HTTP traffic) sees the signed
  session cookie and can replay it. The cookie is signed but not encrypted,
  so the `authenticated_at` timestamp is also disclosed.
- **Fix:** Conditionally set `secure: true` whenever the deployment terminates
  or expects TLS. Easiest: read `:force_ssl` and inherit:

  ```elixir
  @session_options [
    store: :cookie,
    key: "_termigate_key",
    signing_salt: "KIiTW2EZ",
    same_site: "Lax",
    secure: Application.compile_env(:termigate, [:secure_cookies], false)
  ]
  ```

  …and set `:secure_cookies` from runtime.exs alongside the existing
  `TERMIGATE_FORCE_SSL` block.

### [MEDIUM] WebSocket `check_origin` defaults to `false` when `PHX_HOST` is unset
- **Location:** `config/runtime.exs` prod block (the
  `default_check_origin = if configured_host, do: :conn, else: false`
  expression).
- **Issue:** When operators run termigate without setting `PHX_HOST` — which
  the comment notes is the common first-run case for rootless podman /
  Tailscale / LAN — Phoenix's cross-origin WebSocket check is fully
  disabled. The accompanying log warning encourages operators to set
  `PHX_HOST` but does nothing on its own.
- **Impact:** Combined with `same_site: "Lax"` the LiveView WebSocket cookie
  is still attached on top-level navigations, but `Lax` does not block
  WebSocket handshakes initiated by `ws://attacker.example/...` while a
  victim is logged in. With `check_origin: false` the server accepts the
  attacker-origin handshake. The `/socket` channel is still gated by an
  explicit `channel_token`, so terminal panes are safe; but the `/live`
  socket carries the LiveView session (CSRF token + cookie) without that
  second factor and is the larger exposure surface.
- **Fix:** Default to `:conn` (Phoenix's host-matching default) and provide a
  loud opt-out for the first-run case rather than the other way around. If
  the existing UX concern stands, at minimum make `check_origin: false` log
  on every request, not just at boot, and force `:conn` once initial setup
  has finished by re-reading config or restarting the endpoint.

### [MEDIUM] Login logging interpolates raw username into log lines
- **Location:** `lib/termigate_web/controllers/auth_controller.ex:12, 26, 44,
  57`.
- **Issue:** All four login log statements interpolate the user-supplied
  username with `#{username}`. If the username contains `\r\n` (or terminal
  control sequences), the log lines can be split or pollute terminal-based
  log viewers.
- **Impact:** Log injection. Forged log entries can mask brute-force attempts
  from anyone parsing logs visually or with line-oriented grep alerting.
  Telemetry events use the same raw value, so downstream sinks inherit the
  problem.
- **Fix:** Sanitize before logging — strip control characters and cap length:

  ```elixir
  defp sanitize_user(nil), do: "<missing>"
  defp sanitize_user(s) when is_binary(s),
    do: s |> String.replace(~r/[\x00-\x1f\x7f]/, "?") |> String.slice(0, 64)
  ```

  Use the sanitized value in every `Logger` and `:telemetry` call.

### [MEDIUM] `/healthz` discloses auth state to unauthenticated callers
- **Location:** `lib/termigate_web/controllers/health_controller.ex` (whole
  file), routed unauthenticated via `pipe_through :api` in the router.
- **Issue:** The healthz response includes `auth_mode` ("token" /
  "credentials" / "disabled") and `vm_memory_mb`. Anyone who can hit the
  endpoint sees whether termigate is currently running with no auth at all,
  along with coarse memory pressure.
- **Impact:** Pre-auth attacker reconnaissance. The `disabled` value is
  particularly dangerous: it is exactly the signal that says "you can hit
  `/setup` and create the first admin account," because `RequireAuth` itself
  redirects all browser routes to `/setup` whenever
  `Termigate.Auth.auth_enabled?()` is false. An attacker who can reach
  `/healthz` learns when a freshly-deployed termigate is in that window.
- **Fix:** Trim `/healthz` to a minimal liveness probe (`{status: "ok"}` plus
  tmux reachability) and gate `auth_mode`, memory, and stream counts behind
  the existing `metrics_token`. The metrics controller already implements
  this pattern.

### [LOW] Debug-level logging echoes full tmux argv (including send-keys content)
- **Location:** `lib/termigate/tmux/command_runner.ex:13`.
- **Issue:** `Logger.debug("tmux command: #{tmux_path} #{Enum.join(full_args,
  " ")}")`. When the configured log level is `:debug` (the dev default), every
  tmux invocation, including `send-keys`, lands in the log. Send-keys content
  is the user's literal keystrokes — passwords typed into a tmux pane,
  `~/.bash_history` recall, anything else.
- **Impact:** Log files become a mirror of every keystroke routed through
  termigate. Operators who ship debug logs to centralized aggregation will
  leak terminal input outside the tmux session boundary. In production the
  default log level is `:info`, so this is gated by an operator decision —
  hence "low" — but the gating is silent.
- **Fix:** Either redact send-keys argv before logging (replace the payload
  position with `"<n bytes>"` for the `send-keys`/`send-keys -l` subcommands)
  or downgrade the line to `:debug` *only* for non-send-keys commands and
  keep send-keys at `:info` with a fixed, redacted message.

### [LOW] Channel token is not bound to its session
- **Location:** `lib/termigate_web/live/multi_pane_live.ex:48` (sign), and
  `lib/termigate_web/channels/user_socket.ex:14-19` (verify).
- **Issue:** `Phoenix.Token.sign(socket, "channel", %{session: session})`
  signs the session name into the token, but `UserSocket.connect/3` only
  checks `Phoenix.Token.verify(... "channel", token, max_age: max_age)` and
  does not validate the topic against the signed payload. The terminal
  channel `join("terminal:" <> target_raw, ...)` accepts any target and
  subscribes to the corresponding `PaneStream`.
- **Impact:** In termigate's single-user threat model this is benign — the
  legitimate user is allowed on every pane anyway — but it is a
  defense-in-depth gap. If termigate ever grows multi-tenant or per-session
  ACLs, this flow trivially permits horizontal access.
- **Fix:** Pass the session into the channel's `params` (or the topic), and
  in `TerminalChannel.join/3` reject when the joined target's session
  prefix does not match the signed `session` claim. Or scope the token to the
  exact target instead of the session.

### [LOW] Static `TERMIGATE_AUTH_TOKEN` accepts any username
- **Location:** `lib/termigate/auth.ex:19-30`.
- **Issue:** When `TERMIGATE_AUTH_TOKEN` is configured, `verify_credentials/2`
  succeeds whenever `password == token`, regardless of which `username` was
  submitted. Only on a token mismatch does the function fall through to the
  per-user PBKDF2 file check.
- **Impact:** This is documented behavior (the token is an emergency
  bypass / API access secret) but it is invisible to operators who configure
  both a token and a credentialed user. Brute-forcing the token does not need
  the username, and audit log entries for token-based logins record whatever
  username the caller invented.
- **Fix:** If unintended, gate the token branch on a recognized API client
  username (e.g. require `username == "" or username == "_token"`), and log
  token-based logins with a fixed sentinel user instead of the
  caller-supplied string.

### [LOW] Dev endpoint binds `0.0.0.0` by default
- **Location:** `config/runtime.exs` (`config_env() == :dev` block).
- **Issue:** `mix phx.server` listens on `0.0.0.0:8888` by default in dev,
  matching the prod path only when `PHX_BIND=0.0.0.0` is set. This is
  intentional (per project comments, for LAN/emulator testing) but means a
  developer running `mix phx.server` while attached to an untrusted network
  exposes a logged-in session.
- **Impact:** Non-dev networks (cafés, airport WiFi) can reach the dev
  server. Dev mode also enables the live-reloader socket and verbose error
  pages.
- **Fix:** Default dev bind to `127.0.0.1` and require `PHX_BIND=0.0.0.0` to
  opt in. The same env knob already exists for prod; mirroring the behaviour
  removes the divergence.

## Notes and false-positive candidates

The following patterns were considered and dismissed; they should not be
re-flagged in future reviews unless circumstances change.

- **Hardcoded `signing_salt` values.** Both `endpoint.ex:10` and
  `config/config.exs` (`live_view: [signing_salt: "rGgw7trH"]`) hardcode
  signing salts. This is the standard Phoenix pattern: the salt is a
  per-context separator, not a secret. The actual signing key is
  `secret_key_base`, which is sourced from `SECRET_KEY_BASE` at runtime in
  prod (`config/runtime.exs`).
- **tmux command injection via session names, targets, send-keys content.**
  `Termigate.Tmux.CommandRunner.run/1` uses `System.cmd(tmux_path,
  full_args, ...)`, which calls `execvp` directly without a shell. Tmux's
  own argument parsing constrains target syntax (`session:window.pane`); a
  malicious target string yields tmux errors, not arbitrary command
  execution. Session names are additionally validated against
  `~r/^[a-zA-Z0-9_-]+$/` (`tmux_manager.ex:14`).
- **Length-leak in `secure_compare(password, token)`.** `Plug.Crypto.secure_compare/2`
  short-circuits when lengths differ. Token length is not itself
  sensitive (and is operator-set), so the leak does not advance an attack.
- **CSRF on `POST /login` and `DELETE /logout`.** Both routes go through the
  `:browser` pipeline, which includes `:protect_from_forgery`. The login
  template embeds `Plug.CSRFProtection.get_csrf_token()`.
- **PBKDF2 with 100k iterations.** Lower than Argon2id but acceptable for a
  single-user app. `Plug.Crypto.secure_compare` is used on the derived key.
  A dummy-verify branch in `Termigate.Auth.check_file/2` masks
  username-vs-password timing.
- **YAML deserialization of `config.yaml`.** Uses `YamlElixir.read_from_string/1`,
  which does not implement the unsafe tag families that bit Ruby/Python YAML
  loaders. Input is operator-controlled (the file lives in the operator's
  config dir), not attacker-controlled.

## Out of scope / not reviewed

- **Vendored / third-party dependencies.** `mix.lock` and the `deps/` tree
  were not audited line by line; only the manifest in `mix.exs` was reviewed
  for obviously stale or suspicious entries.
- **Android client and assets bundle.** The Kotlin client under
  `android/`, the precompiled JS under `server/priv/static/`, and the
  generated PNG/SVG assets were not inspected. The `xterm.js`/asset toolchain
  in `server/assets/` was only spot-checked.
- **Hermes MCP transport internals.** `Hermes.Server.Transport.StreamableHTTP.Plug`
  is treated as a black box; the review confirms the route is gated by
  `:require_auth_token` + `:rate_limit_mcp` but does not audit the underlying
  library's request parsing.
- **Operator-supplied YAML quick actions.** `quick_actions[].command` is
  saved verbatim and replayed via `PaneStream.send_keys/2`. The actor who
  can write the YAML is the same actor who has shell on the pane, so the
  pattern is intentional rather than an injection vulnerability — but
  reviewing the LiveView dispatch path was deferred.
- **Filesystem permissions on `~/.config/termigate/`.** `write_auth_direct/1`
  sets `0o700` on the directory; this was confirmed but the broader file mode
  story (other config files, log files, fifo dir under `/tmp/termigate/`) was
  not exhaustively walked.
