# Security review

**Date:** 2026-05-02
**Scope:** termigate repo (`server/` Elixir/Phoenix LiveView app)
**Reviewer:** Claude Code

## Summary

Overall the codebase has a thoughtful, defense-in-depth security posture for a
single-user tmux gateway. Authentication uses PBKDF2-HMAC-SHA512 with
self-identifying hashes, constant-time comparisons, dummy-verify against
username enumeration, login rate limiting, a fail-closed first-run setup
gate, IP rewrite that's safe by default, loopback-only metrics, opt-in
cookie `Secure`, and tmux exec done strictly through `System.cmd` arg lists
(no shell interpolation). I did not find any RCE or auth-bypass that's
exploitable today.

The most significant finding is that bearer tokens (and cookie sessions)
are **not invalidated when the operator rotates their password** — both are
signed `Phoenix.Token`/cookie payloads with no revocation linkage to the
current credential. The other issues are smaller posture/defense-in-depth
items: IP-only login rate limiting (no per-account lockout), setup token
written to logs, hardcoded shared `/tmp/termigate` FIFO directory, and
several places that leak internal error structures via `inspect/1`.

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 1     |
| Medium   | 4     |
| Low      | 6     |

## Remediation checklist

Track each finding here as it's addressed. Tick the box when the fix is
merged and a regression test (where applicable) is in place.

- [x] **[High]** Bind `api_token` and cookie session to current credentials (auth-version claim) so password rotation revokes them
- [ ] **[Medium]** Switch `secure_cookies` from `Application.compile_env/3` to `get_env/3` (or default to `true` in prod), pair with `same_site: "Strict"` once on
- [ ] **[Medium]** Add per-username login lockout (independent of source IP) and document a minimum length for `TERMIGATE_AUTH_TOKEN`
- [ ] **[Medium]** Stop logging the setup token in plain log lines; expose it via a CLI helper or one-shot file, switch `/setup` token to a `POST` body
- [ ] **[Medium]** Make the `channel_scope` token mandatory for all channel joins (browser and native), add an explicit `scope: "all"` claim if cross-session access is needed
- [ ] **[Low]** Move FIFO dir off shared `/tmp/termigate` (use `XDG_RUNTIME_DIR` or per-pid subdir), `chmod 0700` the parent, harden `setup_fifo/1` against the symlink race
- [ ] **[Low]** Replace `inspect(reason)` in JSON/flash error responses with mapped, fixed strings; log the inspected reason server-side
- [ ] **[Low]** Add a Content-Security-Policy header tuned for xterm.js, and wire `plug Plug.SSL` (HSTS) when `TERMIGATE_FORCE_SSL=true`
- [ ] **[Low]** Bound `session_ttl_hours` to a sane range and use `Integer.parse/1` so bad input becomes a form error, not a 500
- [ ] **[Low]** Have `Termigate.Config.write_config/2` re-apply `chmod 0600` after every write; add a unit test asserting the resulting mode
- [ ] **[Low]** Extend `safe_args/1` to redact `pipe-pane` shell-command and `new-session` trailing command arg

## Findings

### [High] Password rotation does not revoke active API tokens or web sessions

- **Location:** `server/lib/termigate_web/controllers/auth_controller.ex:30`,
  `server/lib/termigate_web/plugs/require_auth_token.ex:14`,
  `server/lib/termigate_web/plugs/require_auth.ex:13`
- **Issue:** API bearer tokens are minted with
  `Phoenix.Token.sign(TermigateWeb.Endpoint, "api_token", %{username: username})`
  and the verify path only checks `max_age` (default 7 days). The token
  payload contains nothing that ties it to the current password hash, and
  there is no server-side denylist or rotating-secret mechanism. The web
  cookie session stores only `"authenticated_at"` (a unix timestamp) and is
  signed-cookie based, so `clear_session()` on `/logout` only blanks the
  cookie on the client. After an operator rotates `auth.password_hash` (or
  rotates `TERMIGATE_AUTH_TOKEN`) to revoke a compromise, every previously
  issued API token and every browser cookie issued before the rotation
  remains valid until its own TTL expires.
- **Impact:** A stolen bearer token or session cookie cannot be revoked by
  the standard "change your password" workflow that operators expect. An
  attacker who scraped a token from the network, a log file, a Referer
  header, or a backup retains full tmux access — including
  `tmux_send_keys` and `tmux_run_command` via MCP — for up to seven days
  after the password change. There is no admin-visible way to force-cut
  sessions short of restarting the server with a new `SECRET_KEY_BASE`.
- **Fix:** Bind the token to credentials. Two reasonable shapes:
  (a) include a short prefix of the current `password_hash` (or a
  derived `auth_version` integer that bumps on every credential change)
  in the signed payload, and reject in `RequireAuthToken` /
  `AuthHook` / `RequireAuth` when the value no longer matches the active
  config; or (b) on every credential rotation, regenerate
  `secret_key_base` (drastic — invalidates everything) or the
  `Phoenix.Token` signing salt. Option (a) is the standard
  "session version" approach and is straightforward in this codebase
  because `Termigate.Config` already serializes writes through a
  GenServer.

### [Medium] Cookie `Secure` flag defaults to off

- **Location:** `server/lib/termigate_web/endpoint.ex:18-20`,
  `server/config/runtime.exs` (`TERMIGATE_SECURE_COOKIES`)
- **Issue:** `secure: Application.compile_env(:termigate, :secure_cookies, false)`
  defaults to `false` so plain-HTTP loopback / LAN deployments keep
  working. The companion `TERMIGATE_SECURE_COOKIES` env var is read at
  *runtime* but the `Application.compile_env/3` call snapshots the value
  at compile time, so an operator who builds a release with default env
  and later sets `TERMIGATE_SECURE_COOKIES=true` does not actually flip
  the flag — the bit is baked into the BEAM beam.
- **Impact:** On any deployment that's reachable over plain HTTP (the
  default), the auth cookie can be intercepted on the wire. The
  `compile_env` vs runtime mismatch makes this trap silent: the operator
  thinks they enabled it, but the cookie is still emitted without
  `Secure`.
- **Fix:** Either move `secure_cookies` to `Application.get_env/3` so the
  runtime flag actually takes effect (and document that the change
  requires a process restart but not a rebuild), or have `prod.exs`
  default `secure_cookies` to `true` and require the operator to
  *opt out* explicitly for plain-HTTP use. Also recommend pairing with
  `same_site: "Strict"` once Secure is on.

### [Medium] Login rate limit is IP-only with no per-account lockout

- **Location:** `server/lib/termigate_web/plugs/rate_limit.ex:26-34`,
  `server/lib/termigate_web/rate_limit_store.ex:34-49`
- **Issue:** The rate-limit key is `{ip, key, window_minute}` with a default
  of 5 attempts/minute on `:login`. There is no per-username counter and
  no progressive backoff or temporary lockout after repeated failures.
  Behind a Tor exit list, NAT pool, or any small botnet, an attacker
  gets `5 × N` attempts/minute against the single admin account.
- **Impact:** Combined with PBKDF2-HMAC-SHA512 the absolute throughput is
  low, but a determined attacker with even a few dozen IPs can sustain
  thousands of attempts per hour against the admin password indefinitely
  with no operator-visible alerting beyond debug log lines. The
  `TERMIGATE_AUTH_TOKEN` static-token path is also subject to this — and
  there is no minimum length enforced on that token.
- **Fix:** Add a per-username failure counter that locks the account for
  N minutes after M failures (independent of source IP). Optionally emit
  a telemetry event / log a warning at the lockout boundary so operators
  can wire it into alerting. Document a minimum length recommendation
  for `TERMIGATE_AUTH_TOKEN` (e.g. 32+ chars from `mix phx.gen.secret`).

### [Medium] Setup token logged at warning level inside the application logs

- **Location:** `server/lib/termigate/setup.ex:117-139`
- **Issue:** When no admin exists, the setup URL — including the live token
  — is written to the logger via `Logger.warning/1` so operators can
  retrieve it from `podman logs` / `journalctl`. Anyone with read access
  to those logs (other ops staff, log aggregators, sidecar shippers,
  shared CI workers, container debug tooling) can use the token to seize
  the admin account before the legitimate operator finishes setup. The
  token also lives in URL parameters (`/setup?token=…`), so it can be
  preserved in browser history, the Referer header on outbound links, or
  any HTTP proxy access log.
- **Impact:** First-run admin takeover by anyone with log-read or
  browser-history access until `Termigate.Setup.consume/0` runs. This is
  the exact race the setup gate is meant to prevent, but the
  log-channel side-channel reintroduces it.
- **Fix:** Log a static "setup required, fetch token via
  `${0} setup-token`" message and add a small CLI helper (or a shell
  command that reads from a named file) so the token is never written
  into the standard log stream. If logging the token is kept for ergonomics,
  redact it after `consume/0` is called and document the operational risk
  in deploy docs. Consider `POST /setup` instead of `GET` so the token
  isn't preserved in URL-keyed log/history surfaces.

### [Medium] MCP and native API clients bypass per-session channel scoping

- **Location:** `server/lib/termigate_web/channels/terminal_channel.ex`
  (`apply_scope/2` + `authorize_target/2`),
  `server/lib/termigate_web/channels/user_socket.ex`
- **Issue:** Browser channels carry a short-lived `channel_scope` token
  that pins the channel to a single tmux session as defense-in-depth.
  Native API clients authenticated via `x-auth-token` are not required
  to send a scope token — `apply_scope/2` returns `{:ok, socket}` when
  the scope param is missing, and `authorize_target/2` is a no-op when
  `channel_session` is `nil`. So any holder of a valid bearer token can
  join `terminal:<any_session>:<window>:<pane>` and stream output /
  inject keystrokes for any pane the running user can see.
- **Impact:** Token compromise immediately yields full multi-session
  reach, not just the one session a particular client was scoped to.
  Combined with the High finding above (no token revocation), the blast
  radius of a leaked token is "full host shell access until the token
  expires."
- **Fix:** Make scope tokens mandatory for *every* channel join (browser
  and native), and issue them at login alongside the bearer token. If
  some MCP workflows truly need cross-session reach, gate that on a
  separate `scope: "all"` claim baked into the token at issue time so
  it's at least an explicit decision.

### [Low] FIFO directory `/tmp/termigate` is shared and TOCTOU-prone

- **Location:** `server/config/config.exs` (`fifo_dir: "/tmp/termigate"`),
  `server/lib/termigate/pane_stream.ex:555-562` (`setup_fifo/1`)
- **Issue:** The FIFO directory defaults to `/tmp/termigate`, created with
  `File.mkdir_p!/1` (no `chmod` of the parent). Filenames are
  `pane-<digits>.fifo` derived from tmux's pane id with `%` stripped, so
  they are predictable. `setup_fifo/1` does `File.rm/1` then `mkfifo
  -m 0600 <path>` — a local user on the same host can win the rm→mkfifo
  window with a symlink pointing somewhere else, and although the FIFO
  itself is created `0600`, the symlink target is what gets touched. On
  a multi-tenant host the predictable pane-id namespace also means two
  termigate instances under different users can collide on the same
  filename.
- **Impact:** On a single-user dedicated host this is moot. On a shared
  host an unprivileged co-tenant can use the symlink race to either
  deny service (mkfifo fails on a non-empty/locked target) or, in the
  worst case, redirect the FIFO read into a path the termigate user has
  permission to overwrite.
- **Fix:** Default to `Path.join(System.tmp_dir!(), "termigate-#{System.get_pid()}")`
  or `${XDG_RUNTIME_DIR}/termigate`, create the dir with mode `0700`,
  and use `:file.make_dir/1`+`:file.change_mode/2` (or `mkdir -p` then
  `chmod 0700`) so the parent's mode is enforced. Use
  `O_CREAT|O_EXCL`-equivalent semantics by checking
  `File.exists?/1` and aborting if a non-FIFO is found at the target.

### [Low] Internal error structures leaked via `inspect/1` in JSON responses

- **Location:** `server/lib/termigate_web/controllers/quick_action_controller.ex:18`,
  `:30`, `:43`, `:55`;
  `server/lib/termigate_web/live/setup_live.ex` (`Failed to create account: #{inspect(reason)}`)
- **Issue:** When `Termigate.Config.upsert_action/1` (or `delete_action/1`,
  `reorder_actions/1`, `Auth.write_credentials/3`) returns an error,
  the controller renders `inspect(reason)` straight into the JSON
  response body (or the LiveView flash). For atom or string reasons
  this is harmless; for nested tuples, file paths, or stacktrace-like
  structures it leaks server internals to the (authenticated) caller.
- **Impact:** Limited — these endpoints require auth, so the disclosure is
  to a logged-in operator. Still, error-shape disclosure is a
  fingerprinting aid for any post-compromise lateral movement and a
  habit worth breaking before it spreads to unauthenticated paths.
- **Fix:** Pattern-match known error reasons and render fixed strings;
  fall through to a generic "internal error" message and `Logger.error`
  the inspected reason server-side instead of returning it.

### [Low] No Content-Security-Policy or HSTS headers

- **Location:** `server/lib/termigate_web/router.ex:8` (browser pipeline),
  `server/lib/termigate_web/endpoint.ex` (no `:force_ssl` plug)
- **Issue:** `put_secure_browser_headers` sets the Phoenix defaults
  (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, etc.)
  but does not set `Content-Security-Policy` or
  `Strict-Transport-Security`. There is also no `plug Phoenix.LiveView.Router`
  / `plug :force_ssl` line in the endpoint despite the
  `TERMIGATE_FORCE_SSL` env var referenced in comments.
- **Impact:** A stored-XSS in the LiveView templates would have nothing
  to constrain it; a browser that has previously connected over HTTPS
  can be downgraded if a network attacker can intercept the next
  navigation. Both are post-compromise / network-attacker scenarios,
  not standalone bugs.
- **Fix:** Add `put_resp_header(conn, "content-security-policy",
  "default-src 'self'; script-src 'self' 'unsafe-inline'; ...")` (xterm.js
  may need a tuned CSP). When `TERMIGATE_FORCE_SSL=true`, install
  `plug Plug.SSL, hsts: true, expires: 31_536_000, subdomains: true,
  preload: true` in the endpoint.

### [Low] `session_ttl_hours` is unbounded and parsed with `String.to_integer/1`

- **Location:** `server/lib/termigate_web/live/setup_live.ex` (`String.to_integer(params["session_ttl_hours"] || "168")`),
  `server/lib/termigate_web/live/settings_live.ex` (similar pattern when changing TTL)
- **Issue:** The TTL is a free-form integer with no upper bound. A
  malicious or careless operator can set it to e.g. 87600 hours
  (~10 years), in which case every cookie/token issued is effectively
  permanent. `String.to_integer/1` raises on non-numeric input, surfacing
  as a 500 to the legitimate operator (DoS-during-setup, gated by setup
  token) — minor but worth catching.
- **Impact:** Operator footgun + minor info-disclosure on bad input.
- **Fix:** Validate the parsed value is in a sane range
  (e.g. 1 to 8760 hours); use `Integer.parse/1` and reject non-integer
  input with a friendly form error instead of crashing.

### [Low] `Auth.write_direct/1` chmod chain not used in the GenServer write path

- **Location:** `server/lib/termigate/auth.ex` (`write_auth_direct/1`),
  `server/lib/termigate/config.ex` (`write_config/2`)
- **Issue:** The direct-write fallback in `Auth` carefully `mkdir_p`s,
  `chmod`s the directory to `0o700`, writes the file, then `chmod`s the
  file to `0o600`. The normal write path goes through
  `Termigate.Config.update/1` → `write_config/2`, which uses
  `File.write/2` without any explicit `chmod`. So once the
  GenServer is up (the typical case after first boot), subsequent
  config writes inherit the process umask for permissions — and the
  password hash sits in that file.
- **Impact:** On a single-user host with a sane umask (`0022`), the file
  ends up `0644` and the password hash is readable by any local user.
  If a release runs under a dedicated `termigate` user this still leaks
  the hash to anyone with that user's read access.
- **Fix:** Have `Termigate.Config.write_config/2` re-apply
  `File.chmod(path, 0o600)` after every write (and on first creation,
  also ensure the parent directory is `0o700`). Worth adding a unit
  test that asserts the resulting mode.

### [Low] Logger debug echoes the full tmux argv except for `send-keys`

- **Location:** `server/lib/termigate/tmux/command_runner.ex:13`
- **Issue:** `safe_args/1` redacts `send-keys` payloads but every other
  tmux invocation (including `pipe-pane -o "cat >> /tmp/termigate/pane-NNN.fifo"`,
  `new-session ... <command>`) is logged verbatim at debug level. If the
  operator ever raises log level to `:debug` in prod, the exact path of
  every FIFO and the literal command string passed to
  `tmux new-session` end up in logs.
- **Impact:** Operator-controlled / pentester scenario only — debug
  logging is opt-in. Mostly worth documenting.
- **Fix:** Add `pipe-pane` and the trailing `command` arg of
  `new-session` to `safe_args/1`'s redaction list, or just demote those
  log lines to a structured telemetry event without the raw args.

## Notes and false-positive candidates

The following patterns look risky on first glance but are actually safe in
this codebase, noted so they don't get re-flagged on the next pass:

- **`tmux pipe-pane -o "cat >> #{fifo_path}"`** in
  `pane_stream.ex:587` — this *is* a shell-interpreted string passed to
  tmux, but `fifo_path` is built from
  `Path.join(fifo_dir, "pane-#{safe_id}.fifo")` where `safe_id` is the
  tmux pane id (`%NNN`) with `%` stripped, and `fifo_dir` is a compile-time
  application config. No path component is attacker-influenced.
- **`System.cmd("kill", [to_string(os_pid)], ...)`** in
  `pane_stream.ex:860` — `os_pid` comes from `Port.info(port, :os_pid)`,
  not user input.
- **`String.to_existing_atom(log_level)`** in `runtime.exs:59` — limited
  to atoms already loaded by the logger, so the usual
  `String.to_atom`-on-untrusted-input atom-table-exhaustion risk does
  not apply.
- **All TmuxManager command paths (`create_session`, `kill_session`,
  `kill_pane`, `split_pane`, `rename_session`, `kill_window`)** pass
  user-controlled targets via `-t` to `System.cmd("tmux", [...])`. Even
  though only the *new* session name is regex-validated (not
  `kill_session`'s `name` or `kill_pane`'s `target`), `System.cmd` does
  not invoke a shell, so shell-metachar injection is impossible. Worst
  case is a tmux error.
- **`MetricsController` access policy** — loopback / explicit
  `TERMIGATE_PUBLIC_METRICS=true` / bearer token / 404-default. The 404
  default avoids advertising the route, and high-signal fields
  (`auth_mode`, `active_pane_streams`) are deliberately omitted. Sound.
- **`Termigate.Setup.valid_token?/1`** — `Plug.Crypto.secure_compare`,
  state machine wipes the token after `consume/0`, generated via
  `:crypto.strong_rand_bytes(32) |> Base.url_encode64`. The
  one-shot/race-protection design is solid; the only weakness is the
  log channel called out above.
- **Hardcoded dev `secret_key_base` in `config/dev.exs`** — only loaded
  in `MIX_ENV=dev`, runtime.exs raises in `:prod` if `SECRET_KEY_BASE`
  is missing, empty, the placeholder string, or shorter than 32 bytes.
- **`signing_salt: "KIiTW2EZ"` hardcoded in `endpoint.ex`** — Phoenix
  convention; security relies on `secret_key_base`, which is enforced.
- **Timing attack on `Auth.check_file/2`** — handled via dummy
  `verify_password("dummy", stored_hash)` on missing-user, plus
  `Plug.Crypto.secure_compare` on the username. Good.
- **Phoenix `protect_from_forgery`** is applied to the browser pipeline
  and `_csrf_token` is rendered in the login form; API routes are JSON
  with bearer-token auth (CSRF-safe by construction since cookies are
  not used to authenticate API).

## Out of scope / not reviewed

- Vendored deps: `server/deps/`, `server/_build/`, npm packages under
  `server/assets/node_modules/`, lockfile internals
  (`mix.lock`/`package-lock.json`). Versions in `mix.exs` look current
  (Phoenix 1.8.5, Bandit 1.10, LiveView, pbkdf2_elixir, Hermes MCP).
- `Hermes.Server.*` (third-party MCP transport) — only the integration
  surface (router forward, auth pipeline, exposed tool components) was
  audited.
- Frontend XSS surface in `assets/js/hooks/terminal_hook.js` and the
  xterm.js write paths beyond a search for `raw(`/`dangerouslySetInnerHTML`
  in templates (none found in app code).
- Android client (`./packaging/`, `./drive-artifacts/` referenced in
  `.gitignore`) was not part of this review.
- Build scripts, Dockerfile, CI, release tooling — only spot-checked
  (the generated Dockerfile runs as `nobody`, which is good).
- A full call-graph trace of every LiveView `handle_event/3` callback
  for IDOR-style access checks; the system is single-tenant so most
  authz is "are you the admin," but multi-window/pane LiveViews were
  not exhaustively traced.
