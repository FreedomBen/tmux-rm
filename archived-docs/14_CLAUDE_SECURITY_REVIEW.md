# Security review

**Date:** 2026-04-30
**Scope:** Full repo (server, Android client, container, deploy, CI). The
prior review (`archived-docs/13_CLAUDE_SECURITY_REVIEW.md`) covered server-only
— this one re-checks those findings and audits the surfaces it skipped.
**Reviewer:** Claude Code

## Summary

The 10 findings from the prior server-only review are **all still present** in
the current code (no diff against `router.ex`, `metrics_controller.ex`,
`health_controller.ex`, `endpoint.ex`, `auth_controller.ex`, `runtime.exs`,
etc.). On top of those, the broader scope surfaces several new issues:

- **Containerfile runs as root** — every tmux session in the prod container
  is uid 0.
- **Two deployment templates ship publicly known `SECRET_KEY_BASE`
  placeholders** (`compose.yaml`, `deploy/termigate.service`) that will start
  the server unmodified.
- **Android client allows cleartext traffic on every domain** with no
  allowlist; tokens travel `?token=...` in `ws://` URLs.
- **First-run admin takeover window** — `/setup` is reachable from anyone
  who hits the box before the operator runs it, and `/healthz` advertises
  that window via `auth_mode: "disabled"`.
- **Rate limiter trusts `conn.remote_ip` directly**, which is the proxy IP
  behind any reverse proxy.

| Severity | New | Carried over | Total |
| -------- | --- | ------------ | ----- |
| Critical | 0   | 0            | 0     |
| High     | 1   | 2            | 3     |
| Medium   | 4   | 4            | 8     |
| Low      | 3   | 4            | 7     |

## Progress checklist

Tick each box as the finding is addressed. New findings from this review are
marked `(NEW)`; the rest are carried over from
`archived-docs/13_CLAUDE_SECURITY_REVIEW.md` and confirmed still present.

Key:

[x] = fixed
[~] = partially fixed / in Progress
[-] = won't fix / accept risk
[ ] = not fixed yet

### High

- [x] [HIGH] Container runs everything as root — `Containerfile:11-29` `(NEW)`
- [x] [HIGH] Web `POST /login` is not rate-limited — `lib/termigate_web/router.ex:80`
- [x] [HIGH] Non-constant-time comparison on the metrics token — `lib/termigate_web/controllers/metrics_controller.ex:9`

### Medium

- [x] [MEDIUM] `compose.yaml` and `deploy/termigate.service` ship known-string `SECRET_KEY_BASE` — `compose.yaml:9`, `deploy/termigate.service` `(NEW)`
- [-] [MEDIUM] Android client permits cleartext on every host — `android/app/src/main/res/xml/network_security_config.xml:2` `(NEW)`
- [x] [MEDIUM] First-run admin takeover window — `lib/termigate_web/live/setup_live.ex` + `router.ex:75-78` `(NEW)`
- [x] [MEDIUM] Rate limiter and auth logger trust `conn.remote_ip` raw — `lib/termigate_web/plugs/rate_limit.ex` `(NEW)`
- [ ] [MEDIUM] Session cookie does not set the `secure` flag — `lib/termigate_web/endpoint.ex:7-12`
- [ ] [MEDIUM] WebSocket `check_origin` defaults to `false` when `PHX_HOST` is unset — `config/runtime.exs` prod block
- [ ] [MEDIUM] Login logging interpolates raw username into log lines — `lib/termigate_web/controllers/auth_controller.ex`
- [ ] [MEDIUM] `/healthz` discloses `auth_mode` to unauthenticated callers — `lib/termigate_web/controllers/health_controller.ex`

### Low

- [ ] [LOW] Auth token in WebSocket URL query string — `android/.../PhoenixSocket.kt buildWsUrl`, `di/NetworkModule.kt` `(NEW)`
- [ ] [LOW] `android:allowBackup="true"` with no extraction rules — `android/app/src/main/AndroidManifest.xml:11` `(NEW)`
- [ ] [LOW] `Path.expand("~")` for legacy credentials evaluated at compile time — `lib/termigate/auth.ex:13-14` `(NEW)`
- [ ] [LOW] Debug-level logging echoes full tmux argv — `lib/termigate/tmux/command_runner.ex:13`
- [ ] [LOW] Channel token is not bound to its target session — `lib/termigate_web/live/multi_pane_live.ex:48` + `user_socket.ex:14-19`
- [ ] [LOW] Static `TERMIGATE_AUTH_TOKEN` accepts any username — `lib/termigate/auth.ex:19-30`
- [ ] [LOW] Dev endpoint binds `0.0.0.0` by default — `config/runtime.exs` dev block

## Findings — new (this review)

### [HIGH] Container runs everything as root
- **Location:** `Containerfile:11-29` (runtime stage; no `USER` directive).
- **Issue:** The runtime stage installs tmux + curl, copies the release in,
  and runs `CMD ["/app/entrypoint.sh"]` as root. There is no `USER`
  directive, no `--user` default in `Makefile:run-container`, and
  `compose.yaml` keeps `# user: "1000:1000"` commented out. tmux inside the
  container is therefore PID-1-owned by uid 0, and every command an
  authenticated user types runs as root inside the container namespace.
- **Impact:** An authenticated session is equivalent to root in the
  container. Combined with any container-escape (kernel CVE, careless bind
  mount, host tmux socket mount, etc.), this is an instant host-privilege
  jump. Even with podman rootless on the host, the in-container root can
  write to any volume mount.
- **Fix:** Add a non-root user in the runtime stage and make it the default:

  ```dockerfile
  RUN useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin termigate
  USER termigate
  WORKDIR /home/termigate
  ```

  Then either bake the release into `/home/termigate/app` or chown the
  existing `/app`. Update the `compose.yaml` example to show
  `user: "10001:10001"` uncommented as the default.

### [MEDIUM] `compose.yaml` and `deploy/termigate.service` ship known-string `SECRET_KEY_BASE`
- **Location:** `compose.yaml:9` (`SECRET_KEY_BASE=generate-me`);
  `deploy/termigate.service`
  (`Environment=TERMIGATE_SECRET_KEY_BASE=CHANGE_ME_generate_with_mix_phx_gen_secret`).
- **Issue:** Both deploy templates start successfully with placeholder
  secrets. The Phoenix endpoint accepts any non-empty string at the
  `secret_key_base` slot — the `runtime.exs` check raises only when the env
  var is *missing*, not when it equals a publicly known value.
  `packaging/scriptlets/postinst` prints next-steps but does not block
  service start.
- **Impact:** Anyone running `podman compose up` or
  `systemctl start termigate` on a fresh deploy without overriding the
  placeholder gets a server signing cookies with `generate-me` /
  `CHANGE_ME_generate_with_mix_phx_gen_secret`. Both strings are public on
  GitHub. Cookie forgery is then trivial: an attacker who can reach the
  server signs an `authenticated_at` cookie and bypasses login.
- **Fix:** Validate in `runtime.exs` (prod block) and in
  `deploy/container-entrypoint.sh`:

  ```elixir
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil -> raise "SECRET_KEY_BASE missing"
      v when byte_size(v) < 32 -> raise "SECRET_KEY_BASE too short"
      "CHANGE_ME" <> _ -> raise "SECRET_KEY_BASE is the placeholder"
      "generate-me" -> raise "SECRET_KEY_BASE is the placeholder"
      v -> v
    end
  ```

  And remove the placeholder from `compose.yaml` (force the operator to
  override).

### [MEDIUM] Android client permits cleartext on every host
- **Location:** `android/app/src/main/res/xml/network_security_config.xml:2`
  (`<base-config cleartextTrafficPermitted="true" />`).
- **Issue:** The base config grants HTTP everywhere. The auth token is sent
  as `Authorization: Bearer …` on HTTP API calls and as `?token=…` in
  `ws://` URLs (`PhoenixSocket.kt buildWsUrl`). The token is stored
  on-device in `EncryptedSharedPreferences` (good) but goes over the wire in
  plain text whenever the user types an `http://` URL.
- **Impact:** An attacker on the same Wi-Fi (café, airport, even the user's
  home if compromised) sees the bearer token in transit, then has full
  session access — every API surface, every tmux pane, indefinitely
  (`auth_token_max_age = 604_800` = 7 days).
- **Fix:** Replace the blanket `base-config` with explicit allowlists for
  the loopback shapes the README documents:

  ```xml
  <network-security-config>
    <domain-config cleartextTrafficPermitted="true">
      <domain includeSubdomains="false">10.0.2.2</domain>
      <domain includeSubdomains="false">127.0.0.1</domain>
      <domain includeSubdomains="false">localhost</domain>
    </domain-config>
    <base-config cleartextTrafficPermitted="false" />
  </network-security-config>
  ```

  Real LAN/Tailscale deployments should expose HTTPS via Caddy/nginx; that
  aligns with the comment block in `runtime.exs` about TLS terminators.

### [MEDIUM] First-run admin takeover window
- **Location:** `lib/termigate_web/live/setup_live.ex` (entire LiveView),
  `lib/termigate_web/router.ex:75-78` (mounted in `:browser` only — no rate
  limit, no IP gate), `lib/termigate_web/plugs/require_auth.ex`
  (`else conn |> redirect(to: "/setup")`).
- **Issue:** When `Auth.auth_enabled?()` returns false, every browser route
  redirects to `/setup`, and `/setup`'s `phx-submit` handler creates the
  admin account from whatever username/password the form submitter
  provides. `/healthz` advertises this state as `auth_mode: "disabled"`.
  The protection is purely operational ("set up before exposing"). The race
  is reachable from anywhere `bind_ip = {0, 0, 0, 0}` reaches.
- **Impact:** An attacker who can reach the host between deploy and
  first-run owns the install. Combined with the prior `/healthz` finding,
  any internet-reachable termigate is hijackable until the operator clicks
  through `/setup`.
- **Fix:** Either (a) require a one-shot `TERMIGATE_SETUP_TOKEN` env var
  that the setup form must echo, removed after first success, or (b) only
  allow `/setup` from `127.0.0.1` until the first admin exists. Option (a)
  is operator-friendlier; the entrypoint can generate the token and print
  it to logs.

### [MEDIUM] Rate limiter and auth logger trust `conn.remote_ip` raw
- **Location:** `lib/termigate_web/plugs/rate_limit.ex` (`ip = conn.remote_ip
  |> :inet.ntoa() |> to_string()`); `lib/termigate_web/plugs/require_auth.ex`
  `remote_ip/1` (same pattern); `lib/termigate_web/controllers/auth_controller.ex`
  log lines.
- **Issue:** `conn.remote_ip` is the *socket* peer. Behind any reverse proxy
  (Caddy, Nginx, Traefik, or even podman's port-publish), this is the
  proxy's IP, so login rate limits become `{5, 60}` per *proxy*, not per
  *client*. The same flatness shows up in the auth log, which records the
  proxy IP for every brute-force attempt.
- **Impact:** Login throttling is effectively disabled in any fronted
  deployment. The high-severity `/login` rate-limit gap from the prior
  review is therefore worse than it looks: even after you wrap it in
  `:rate_limit_login`, all PBKDF2-burning attempts share a single bucket.
- **Fix:** Add `Plug.RemoteIp` (`:remote_ip` hex package) ahead of the
  rate-limit plug, configured with the IPs of the trusted proxies. Document
  the operator-side requirement in `deploy/`.

### [LOW] Auth token in WebSocket URL query string
- **Location:** `android/app/src/main/java/org/tamx/termigate/data/network/PhoenixSocket.kt`
  (`buildWsUrl`), `android/app/src/main/java/org/tamx/termigate/di/NetworkModule.kt`
  (`params = prefs.authToken?.let { mapOf("token" to it) }`).
- **Issue:** The token is encoded into the WebSocket URL as
  `?token=<token>`. Even over TLS, URLs land in proxy access logs, NAT
  logs, and `Referer` headers if any HTML pages pull `ws://` resources.
  With cleartext allowed (above), the URL is also visible on-path.
- **Impact:** Any log aggregator that captures the WS URL captures the
  bearer. Token rotation is not implemented (token == apiClient.login
  response, persisted indefinitely until logout), so the leak is durable.
- **Fix:** Either send the token via `Sec-WebSocket-Protocol` (Phoenix's
  `UserSocket.connect/3` already pulls from `params`, so the cleanest path
  is to send it in an initial channel `phx_join` payload over an
  unauthenticated socket) or treat the WebSocket URL as a secret and avoid
  logging it.

### [LOW] `android:allowBackup="true"` with no extraction rules
- **Location:** `android/app/src/main/AndroidManifest.xml:11`.
- **Issue:** `allowBackup="true"` and no `dataExtractionRules` /
  `fullBackupContent` means Android Auto Backup ships
  `EncryptedSharedPreferences` (and the SharedPreferences containing
  `serverUrl`, `lastUsername`) up to Google Drive. Encrypted prefs can't be
  decrypted on a different device, but the encrypted blob and the plain
  prefs leak.
- **Impact:** The encrypted token blob is encrypted by the device keystore;
  restoring it elsewhere yields ciphertext. But `lastUsername` and
  `serverUrl` are plaintext under Auto Backup, identifying the deployment
  to anyone who gains the user's Google account.
- **Fix:** Either set `android:allowBackup="false"`, or add a
  `data_extraction_rules.xml` excluding both pref files.

### [LOW] `Path.expand("~")` for legacy credentials evaluated at compile time
- **Location:** `lib/termigate/auth.ex:13-14`.
- **Issue:** `@legacy_credentials_dir Path.expand("~/.config/termigate")` is
  a module attribute, so `~` is expanded at *compile* time using the build
  environment's `HOME`. In a Containerfile build that's `/root` (or
  whatever the build user is); at runtime in the deployed container the
  effective HOME may be different (especially after the proposed non-root
  `USER` change above).
- **Impact:** The legacy credential read either targets a directory that
  doesn't exist (silent miss) or — if the build-time and run-time paths
  happen to coincide — picks up files belonging to a different user. Not
  directly exploitable but operationally surprising.
- **Fix:** Change to a function call so it evaluates at runtime:
  `defp legacy_credentials_dir, do: Path.expand("~/.config/termigate")`.

## Findings — carried over from `archived-docs/13_CLAUDE_SECURITY_REVIEW.md`

Verified each is unchanged in the current code. Full descriptions, impacts,
and recommended fixes remain accurate as written there.

| Severity | Title                                                                | Location                                                               |
| -------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| HIGH     | Web `POST /login` is not rate-limited                                | `lib/termigate_web/router.ex:80`                                       |
| HIGH     | Non-constant-time comparison on the metrics token                    | `lib/termigate_web/controllers/metrics_controller.ex:9`                |
| MEDIUM   | Session cookie does not set the `secure` flag                        | `lib/termigate_web/endpoint.ex:7-12`                                   |
| MEDIUM   | WebSocket `check_origin` defaults to `false` when `PHX_HOST` is unset | `config/runtime.exs` prod block                                        |
| MEDIUM   | Login logging interpolates raw username into log lines               | `lib/termigate_web/controllers/auth_controller.ex`                     |
| MEDIUM   | `/healthz` discloses `auth_mode` to unauthenticated callers          | `lib/termigate_web/controllers/health_controller.ex`                   |
| LOW      | Debug-level logging echoes full tmux argv                            | `lib/termigate/tmux/command_runner.ex:13`                              |
| LOW      | Channel token is not bound to its target session                     | `lib/termigate_web/live/multi_pane_live.ex:48` + `user_socket.ex:14-19` |
| LOW      | Static `TERMIGATE_AUTH_TOKEN` accepts any username                   | `lib/termigate/auth.ex:19-30`                                          |
| LOW      | Dev endpoint binds `0.0.0.0` by default                              | `config/runtime.exs` dev block                                         |

## Notes and false-positive candidates

- **MCP `tmux_send_keys` / `tmux_run_command` not validating `target`
  format** (`mcp/tools/run_command.ex`, `mcp/tools/send_keys.ex`). The
  server uses `System.cmd` (argv, no shell) and the bearer-token holder
  already has full tmux access — invalid targets produce tmux errors, not
  RCE. Not a finding.
- **Quick action commands replayed via `send_keys`.** Operator-supplied
  YAML, replayed as keystrokes only — same actor controls both ends. Not a
  finding (matches prior FP note).
- **Hermes MCP transport.** Gated by `:require_auth_token` +
  `:rate_limit_mcp` (120/60s). Library internals not audited.
- **CI workflows.** `pull_request:` (not `pull_request_target:`); release
  job is tag-gated; secrets only flow into the tag-triggered job. No
  finding.
- **Containerfile uses `apt-get install -y --no-install-recommends` and
  cleans `/var/lib/apt/lists`.** Standard hygiene, no finding. The `curl`
  install is solely for the `HEALTHCHECK`; could be replaced by Elixir's
  HTTP client to drop a tool, but this is not a security issue.

## Out of scope / not reviewed

- `mix.lock` and `deps/` not audited line by line.
- Hermes MCP transport library internals (treated as a black box).
- xterm.js / esbuild / Tailwind toolchain output under
  `server/priv/static/` (built artifacts, untracked in this checkout).
- Android `RemoteTerminalSession.kt`, the foreground service, and
  notification handling — only network/auth surface inspected.
- Filesystem permissions on `/tmp/termigate/` fifo dir at runtime
  (verified the `%`-stripping in `pane_stream.ex:fifo_path/2`, but didn't
  audit umask/dir mode end-to-end).
