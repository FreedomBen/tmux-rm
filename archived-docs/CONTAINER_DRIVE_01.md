# Container Drive 01 — Prod Container Test Notes

Date: 2026-04-28
Image: `localhost/termigate:latest` built from `main` (commit `eabd29d`)
How tested:
- `make build-container` → built fresh image
- `podman run -p 8889:8888 -e PHX_HOST=127.0.0.1 -v /tmp/termigate-test-config:/root/.config/termigate:Z ...` (see "Bug 2" for why a port/host override was needed)
- Browsed via Chrome DevTools MCP → setup → login → created `test_session` → split pane → new window → typed commands

## What works

- Build (`make build-container`): clean, ~3 min, exit 0.
- Container starts and the entrypoint auto-creates a `main` tmux session.
- `/healthz` returns 200.
- Setup wizard creates account; login redirects to home; session list shows tmux state.
- Creating a session (`test_session`), creating a window, splitting horizontally, and switching tabs all worked.
- Terminal input via the on-page textbox sent keystrokes to the pane and stdout streamed back correctly (verified `echo`, `uname -a`, `pwd`, `date`, `cat /etc/os-release`, `id`).
- Settings page renders all sections (quick actions, notifications, appearance, auth, password change, config file).
- The PaneStream channel logs (`PaneStream started`, `viewers 0 → 1`, `JOINED terminal:...`) look healthy.

## Bugs / issues found

### 1. PWA icons 404 in prod release (real bug)

**Severity:** medium — UI looks broken (no favicon, no PWA install icon), browser shows two 404s on every page.

The root layout uses verified routes:
```
<link rel="icon" href={~p"/favicon.ico"} sizes="any" />
<link rel="icon" type="image/png" sizes="192x192" href={~p"/icon-192.png"} />
<link rel="apple-touch-icon" href={~p"/apple-touch-icon.png"} />
```
In prod, `~p` rewrites these to the digested forms, e.g. `/favicon-40f750a767a684d153dd7fd3029670f1.ico?vsn=d`. The files exist on disk inside the container at `/app/lib/termigate-0.1.0/priv/static/`, but `Plug.Static`'s `only:` whitelist in `lib/termigate_web.ex:20-22` lists exact basenames:

```elixir
def static_paths,
  do: ~w(assets fonts images favicon.ico apple-touch-icon.png icon-192.png icon-512.png robots.txt openapi.yaml)
```

`Plug.Static` matches `only:` as path **prefixes**, so:
- `/favicon.ico` → 200 ✓
- `/favicon-40f750a767a684d153dd7fd3029670f1.ico` → 404 ✗ (does not start with `favicon.ico`)
- `/icon-192.png` → 200 ✓
- `/icon-192-e7ea7c2e8e5f4d520c9fbb896764cfec.png` → 404 ✗

**Suggested fix:** drop the extensions in the whitelist so the digest-stem still matches:
```elixir
~w(assets fonts images favicon apple-touch-icon icon-192 icon-512 robots openapi)
```
(or list both forms). Worth verifying robots.txt — it currently works because the digested form `robots-9e2c81b0855bbff2baa8371bc4a78186.txt` is not referenced in any HTML, but `~p"/robots.txt"` would have the same issue if added to a route.

### 2. LiveView WebSocket 403 unless `PHX_HOST` matches the URL host

**Severity:** medium — first-run experience is broken for anyone visiting the container by IP or hostname.

`config/runtime.exs:52` defaults `PHX_HOST=localhost`. Phoenix's default `check_origin` accepts only the configured host. The Makefile's `run-container` target does not pass `PHX_HOST`, so visiting the container at `http://127.0.0.1:8889/` causes:

```
WebSocket connection to 'ws://127.0.0.1:8889/live/websocket?...' failed: 403
```

LiveView then falls back to long-poll, but the `/setup` page's `<form phx-submit="setup">` *does* depend on the LiveView channel — if WS is blocked and longpoll hasn't connected yet, **the "Create Account" button silently does nothing** (I hit this on first try; reproduced reliably).

Reproduction: stop the container, wipe `${CONFIG_DIR}`, run `make run-container CONTAINER_PORT=8889 CONFIG_DIR=/tmp/termigate-test-config`, browse `http://127.0.0.1:8889/setup`, fill the form, click Create Account → no navigation, no error, console shows the 403.

**Suggested fixes (any of):**
- Add `PHX_HOST` to the Makefile run-container target with a sensible default (e.g. document overriding it).
- Set `check_origin` to a permissive list in prod runtime config when `PHX_HOST` isn't set.
- Add an explicit warning in the startup log if `PHX_HOST=localhost` and `PHX_BIND=0.0.0.0` (likely-broken combo).

### 3. `HEALTHCHECK` directive ignored by podman's default OCI build

`make build-container` prints during the build:

```
[2/2] STEP 10/12: HEALTHCHECK ... CMD curl -f http://localhost:8888/healthz || exit 1
time="..." level=warning msg="HEALTHCHECK is not supported for OCI image format and will be ignored. Must use `docker` format"
```

The `HEALTHCHECK` in `Containerfile:20` does nothing under podman's default OCI manifest. Either:
- Add `--format docker` to `build-container` in the Makefile, or
- Drop the HEALTHCHECK from the Containerfile and rely on a `--health-cmd` flag in the run command, or
- Document that healthchecks require a non-default build flag.

(Inside the container, `curl` is installed precisely for this healthcheck — if it's never executed, that's wasted image weight.)

### 4. `localhost` resolves to IPv6 first; rootless podman publishes IPv4 only

**Severity:** low — environment-specific, but easy to hit on Fedora.

With pasta networking, `podman run -p 8889:8888 ...` listens only on `0.0.0.0:8889`. `curl http://localhost:8889/` resolves to `::1` first and fails with `Connection reset by peer`. `http://127.0.0.1:8889/` works.

Worth a one-line note in `README.md` or wherever the container quickstart lives: "Use `127.0.0.1`, not `localhost`, with rootless podman."

### 5. Accessibility: many icon-only buttons have no accessible name

Settings page (`/settings`) has at least 16 buttons with empty accessible names — every quick-action edit/delete/up/down icon, plus the unlabeled button next to the pane label in the terminal toolbar (`uid=8_16` in the snapshot, between "pane 0" and the Terminal input textbox). Screen-reader users would hear "button" with no context.

Add `aria-label` (or visible text via `<.icon …>` plus `<span class="sr-only">`) to those controls.

### 6. Other / minor

- **`apple-mobile-web-app-capable` deprecated**: console warns that this meta is deprecated and `mobile-web-app-capable` should also be included. `root.html.heex:6` only sets the apple form.
- **No PWA manifest**: `/manifest.webmanifest` and `/manifest.json` both 404. The page sets `apple-mobile-web-app-capable=yes` but ships no manifest, so on Android Chrome the install prompt won't fire.
- **`No cols/rows in join params: []` log on every channel join**: `terminal_channel` logs at info level when the JS hook joins without sending dimensions. Either the hook should send cols/rows on join, or the log should be debug-level. tmux ends up with a default `[120x40]` layout regardless of the actual viewport.
- **Setup page has no logo image**: `/login` shows the `termigate-logo.png`; `/setup` only shows the text "termigate". Minor branding inconsistency.
- **Snapshot duplicate uid `5_4` for both Settings and Log out** in the a11y tree — probably the same DOM `id` attribute being reused. Worth a quick check for duplicate ids in `multi_pane_live.ex` / app shell.
- **Settings "Config File" wording**: shown as `~/.config/termigate/config.yaml`. In the container `~` is `/root` (since `USER` is unset and the entrypoint runs as root). If anyone tries `cd ~/.config/termigate` from a non-root host shell expecting that path to apply to *them*, they'll be confused. Consider showing the resolved absolute path.
- **`podman stop` falls back to SIGKILL after 10s**: the container does not respond to SIGTERM, podman warns `StopSignal SIGTERM failed to stop container termigate in 10 seconds, resorting to SIGKILL`. Likely the Elixir release isn't trapping SIGTERM through the entrypoint shell — running `exec /app/bin/termigate start` *should* hand off the signal, but something in between (possibly the `tmux new-session -d -s main` line, or the release start script not handling SIGTERM cleanly under a non-tty exec) is swallowing it. Means slow shutdowns and risk of unsaved state.

## How to reproduce the test environment

```sh
# Build
make build-container

# Run on a non-default port with a clean config and the right origin
podman run --rm -d --name termigate \
  -p 8889:8888 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=127.0.0.1 \
  -v /tmp/termigate-test-config:/root/.config/termigate:Z \
  termigate:latest

# Then browse http://127.0.0.1:8889/  (NOT localhost)
```

If `PHX_HOST` is omitted or the URL host differs from it, the setup page is non-functional (Bug 2).
