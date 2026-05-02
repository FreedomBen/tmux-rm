# Security review

**Date:** 2026-05-02
**Scope:** `/home/ben/gitclone/termigate`
**Reviewer:** Codex

## Summary

Termigate has several good security patterns in place: tmux execution usually goes through argv-based `System.cmd/3`, credentials are stored outside the repo, login is rate limited, setup is token-gated, and both Elixir and npm audit checks were clean. The largest risk is that the application fails open when no admin account or auth token is configured: the setup page is protected, but the API, Phoenix channels, and MCP endpoint remain reachable and can control tmux. The Android client and deployment files also default toward cleartext or non-persistent auth in ways that can expose terminal access in real deployments.

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 1     |
| Medium   | 4     |
| Low      | 3     |

## Remediation checklist

- [x] **[HIGH]** Fail closed when no auth is configured — gate `/api/*`, `/mcp`, and `/socket` behind setup completion, and add regression tests
- [ ] **[MEDIUM]** Persist the container config path so auth survives restarts (set `TERMIGATE_CONFIG_PATH` or `HOME` to a mounted volume; warn on misconfiguration)
- [ ] **[MEDIUM]** Unify LiveView and HTTP session TTLs on `Termigate.Auth.session_ttl_seconds/0`; recheck TTL on LiveView events, not just mount
- [ ] **[MEDIUM]** Move browser channel auth off URL query tokens (prefer signed session cookie via `connect_info`; if a token remains, make it short-lived and rotate on reconnect)
- [ ] **[MEDIUM]** Default Android to HTTPS/WSS for bare hostnames; restrict cleartext to debug builds or explicit local domains; require explicit confirmation for `http://` URLs
- [ ] **[LOW]** Add `Termigate.Config.public_view/0` (or equivalent) to strip `auth.password_hash` and other secrets from `GET /api/config`
- [ ] **[LOW]** Require `TERMIGATE_METRICS_TOKEN` by default for `/metrics` (or bind to loopback); gate unauthenticated metrics behind an explicit opt-in
- [ ] **[LOW]** Migrate password hashing to Argon2id/bcrypt with self-identifying parameters; verify/migrate existing PBKDF2 hashes on login; correct packaging docs

## Findings

### [HIGH] API, WebSocket, and MCP access fail open before auth is configured

- **Location:** `server/lib/termigate_web/plugs/require_auth_token.ex:10`, `server/lib/termigate_web/plugs/require_auth_token.ex:26`, `server/lib/termigate_web/channels/user_socket.ex:10`, `server/lib/termigate_web/channels/user_socket.ex:38`, `server/lib/termigate_web/router.ex:33`, `server/lib/termigate_web/router.ex:53`, `server/lib/termigate/mcp/tools/run_command_in_new_session.ex:24`
- **Issue:** `RequireAuthToken` returns the connection unchanged when `Termigate.Auth.auth_enabled?/0` is false, and `UserSocket.connect/3` accepts all socket connections in the same state. The router places tmux management APIs and the MCP endpoint behind those checks, so a fresh or reset instance exposes tmux operations before setup. The MCP tool surface includes command execution workflows.
- **Impact:** Anyone who can reach a fresh exposed instance can list sessions, read panes, send keystrokes, create sessions, kill panes/sessions, or run commands as the termigate OS user through MCP before an admin account exists.
- **Fix:** Fail closed whenever no auth is configured. Keep only `/healthz`, `/login`, and the token-gated `/setup` path reachable during first-run setup. Make `RequireAuthToken` return `503 setup_required` or `401` while `Termigate.Setup.required?/0` is true, and make `UserSocket.connect/3` return `:error` in the same state. Add regression tests that verify `/api/*`, `/mcp`, and `/socket` are denied before setup.

### [MEDIUM] Container service does not persist the config path that stores auth

- **Location:** `deploy/termigate-container.service:49`, `deploy/termigate-container.service:57`, `deploy/termigate-container.service:58`, `server/lib/termigate/config.ex:671`, `Containerfile:37`
- **Issue:** The container service publishes and removes/recreates a container, mounts `/etc/termigate` read-only, and mounts a writable `/var/lib/termigate` volume, but the application defaults its config to `${HOME}/.config/termigate/config.yaml`. In the image, `${HOME}` is `/home/termigate`, which is not mounted by the service.
- **Impact:** A service restart or container recreation can discard the admin credentials and return the instance to the unauthenticated first-run state. Combined with the fail-open API/channel/MCP behavior above, this can repeatedly create unauthenticated terminal-control windows.
- **Fix:** Set `TERMIGATE_CONFIG_PATH=/var/lib/termigate/config.yaml` in the container service and compose examples, or set `HOME=/var/lib/termigate` and document it. Mount that path read-write. Add a startup warning or refusal when running a container with auth config in an unmounted home directory.

### [MEDIUM] LiveView sessions do not enforce the configured session TTL

- **Location:** `server/lib/termigate_web/live/auth_hook.ex:6`, `server/lib/termigate_web/live/auth_hook.ex:13`, `server/lib/termigate_web/plugs/require_auth.ex:18`, `server/config/config.exs:29`, `server/lib/termigate_web/live/settings_live.html.heex:590`
- **Issue:** HTTP requests use `Termigate.Auth.session_ttl_seconds/0`, which reads the configured `session_ttl_hours`. LiveView mounts use a separate `:auth_session_ttl_days` setting with a 30-day default, and already-open LiveView sessions are not rechecked on events.
- **Impact:** If an operator sets the UI session duration to a short value such as 1 hour, an existing LiveView socket or reconnect can remain usable far longer than intended. A stolen signed session cookie also has a larger practical window on LiveView paths than the settings UI indicates.
- **Fix:** Remove the separate `:auth_session_ttl_days` path and have `AuthHook` call `Termigate.Auth.session_ttl_seconds/0`, matching `RequireAuth`. Add an attached LiveView hook or periodic timer that disconnects/redirects when `authenticated_at` exceeds the configured TTL, not just during mount.

### [MEDIUM] Browser channel tokens are sent in WebSocket query parameters

- **Location:** `server/lib/termigate_web/live/multi_pane_live.ex:48`, `server/assets/js/hooks/terminal_hook.js:731`, `server/assets/js/hooks/terminal_hook.js:742`, `server/lib/termigate_web/channels/user_socket.ex:13`, `server/lib/termigate_web/channels/user_socket.ex:15`
- **Issue:** The browser terminal channel token is rendered into the page and passed to `new Socket("/socket", {params: {token}})`, which places it in the WebSocket URL query string. The server verifies it with the full auth session TTL.
- **Impact:** Reverse proxies and access logs commonly record request URLs. Anyone who obtains a logged channel token before expiry can attach to the scoped tmux session and read or send terminal I/O for that session.
- **Fix:** Prefer authenticating browser sockets with the signed session cookie in `connect_info` instead of a URL token. If a channel token remains necessary, make it very short-lived, single-purpose, and rotate it on reconnect. Also document proxy log redaction for `/socket/websocket` query strings.

### [MEDIUM] Android permits and defaults to cleartext terminal transport

- **Location:** `android/app/src/main/res/xml/network_security_config.xml:3`, `android/app/src/main/java/org/tamx/termigate/data/repository/AppPreferences.kt:50`, `android/app/src/main/java/org/tamx/termigate/data/repository/AppPreferences.kt:52`, `android/app/src/main/java/org/tamx/termigate/data/network/ApiClient.kt:36`, `android/app/src/main/java/org/tamx/termigate/data/network/AuthInterceptor.kt:21`, `android/app/src/main/java/org/tamx/termigate/data/network/PhoenixSocket.kt:112`
- **Issue:** The Android app globally permits cleartext traffic, and bare server hostnames are normalized to `http://`. Login requests send the username/password over the resulting URL, bearer tokens are attached to subsequent API calls, and WebSockets downgrade `http://` to `ws://`.
- **Impact:** On a LAN, captive network, or public network, an active or passive network attacker can capture credentials/tokens or tamper with terminal traffic when the user enters a bare host or otherwise uses HTTP.
- **Fix:** Default bare hosts to `https://`. Restrict cleartext to debug builds or explicit domain-config entries for local development hosts such as `10.0.2.2`, `localhost`, and operator-approved LAN hosts. Add an explicit insecure-connection confirmation before saving any `http://` server URL.

### [LOW] Auth password hashes are returned by the config API

- **Location:** `server/lib/termigate_web/controllers/config_controller.ex:6`, `server/lib/termigate_web/controllers/config_controller.ex:8`, `server/lib/termigate/config.ex:467`, `server/lib/termigate/config.ex:607`
- **Issue:** `GET /api/config` returns `Config.get()` directly. The config model preserves the `auth` section, including `password_hash`, so any authenticated API client can retrieve the password verifier.
- **Impact:** A stolen or delegated API token can be used to extract the password hash and attempt offline cracking after the token expires. The client does not need the hash for normal operation.
- **Fix:** Add a public serialization function such as `Termigate.Config.public_view/0` that removes `auth.password_hash` and any future secrets. Return only nonsecret auth metadata such as `session_ttl_hours` where needed.

### [LOW] Metrics are public unless a token is configured

- **Location:** `server/lib/termigate_web/router.ex:40`, `server/lib/termigate_web/router.ex:44`, `server/lib/termigate_web/controllers/metrics_controller.ex:5`, `server/lib/termigate_web/controllers/metrics_controller.ex:19`
- **Issue:** `/metrics` is unauthenticated by default and only requires a bearer token when `TERMIGATE_METRICS_TOKEN` is set.
- **Impact:** Public deployments leak auth mode, process counts, memory usage, uptime, and active pane-stream counts. That information can support reconnaissance and operational fingerprinting.
- **Fix:** Require `TERMIGATE_METRICS_TOKEN` by default for `/metrics`, or bind metrics to loopback. If unauthenticated metrics are needed for local probes, gate that with an explicit `TERMIGATE_PUBLIC_METRICS=true` setting.

### [LOW] Password hashing parameters are weakly versioned and lower-cost than the docs imply

- **Location:** `server/lib/termigate/auth.ex:11`, `server/lib/termigate/auth.ex:161`, `server/lib/termigate/auth.ex:165`, `packaging/config.example.yaml:6`
- **Issue:** Passwords are hashed with PBKDF2-HMAC-SHA256 at 100,000 iterations and serialized as `salt$hash` without an algorithm or work-factor marker. The packaging example describes bcrypt hashes, which does not match the implementation.
- **Impact:** If `config.yaml` or the config API leaks a hash, offline cracking is cheaper than it would be with a memory-hard password hash, and future work-factor migration is harder because stored hashes do not self-identify their algorithm.
- **Fix:** Move new hashes to Argon2id or bcrypt through a maintained Elixir password library, store algorithm and parameters in the hash string, and verify/migrate existing PBKDF2 hashes on successful login. Update the packaging docs to match the actual format.

## Notes and false-positive candidates

- `mix hex.audit` reported no retired Elixir packages, and `npm audit --omit=dev --audit-level=low` reported 0 npm vulnerabilities for `server/assets`.
- Most tmux calls use `System.cmd/3` with argv lists, not shell-interpolated command strings. The remaining `pipe-pane` shell string uses a FIFO path derived from the configured FIFO directory and tmux pane IDs, which are `%` plus digits in normal tmux behavior.
- Terminal toolbar labels are HTML-escaped in `terminal_hook.js` before insertion with `innerHTML`, and quick-action labels are rendered through HEEx escaping.
- Android bearer tokens are stored with `EncryptedSharedPreferences`; the main remaining mobile token risk found here is transport security, not local storage.
- Login usernames are stripped of control characters before logging, and tmux `send-keys` payloads are redacted from debug logs.

## Out of scope / not reviewed

- Vendored dependencies and generated outputs were not audited line by line, including `server/assets/node_modules`, `server/priv/static`, Android Gradle wrapper binaries, and bundled terminal library internals.
- Lockfiles were not manually audited package by package beyond running the available Hex and npm audit commands.
- No Gradle vulnerability database scan was run; the Android dependency review was limited to manifests, dependency declarations, and security-sensitive client code paths.
