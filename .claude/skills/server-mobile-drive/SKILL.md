---
name: server-mobile-drive
description: End-to-end browser drive test of the termigate server on mobile viewport sizes. Builds and runs the prod container in isolation from the host's termigate, drives it via the Chrome DevTools MCP browser emulating a phone, completes initial setup, creates a test session, attaches to it, runs commands to verify the streaming pipeline, and writes mobile-focused findings to a Markdown report. Trigger with `/server-mobile-drive [REPORT.md]`. With no argument, writes to `archived-docs/SERVER_MOBILE_DRIVE_yyyy-mm-dd_HH-MM-SS.md` at the repo root using the current date and time.
---

# Server mobile drive test

End-to-end exercise of the termigate server in its production
container, driven through the browser at **mobile viewport sizes**
with the Chrome DevTools MCP tools. All findings go into a Markdown
report file. The focus is mobile UX: touch targets, layout reflow at
narrow widths, the on-screen keyboard interaction with the terminal,
and any feature that should adapt for small screens.

## Target report file

The path is the skill argument (e.g. `/server-mobile-drive my-report.md`).

If no argument is given, default to
`archived-docs/SERVER_MOBILE_DRIVE_yyyy-mm-dd_HH-MM-SS.md` at the repo
root, where the timestamp is the current date and time (compute with
`date +%Y-%m-%d_%H-%M-%S`). Resolve relative paths from the repo root.

If the file already exists, ask the user whether to overwrite, append,
or pick a different path before continuing.

Initialize the file at the start with a header recording:

- Drive date and time.
- Container image tag and host port.
- Admin credentials used.
- Browser used for the drive (Chromium via Chrome DevTools MCP).
- **Emulated device profile** (name, width × height, device pixel
  ratio, mobile flag, touch flag, user-agent).

Then add an empty `## Findings` section. **Append findings as you
discover them, not at the end.** Each entry includes:

- Short title.
- Severity: `blocker`, `major`, `minor`, or `nit`.
- Numbered repro steps.
- **Viewport** the issue reproduces at (e.g. `iPhone SE 375×667`).
- Expected vs. actual behavior.
- Screenshot path if captured (save under `drive-artifacts/`).

## Isolate from the host's termigate

The host typically runs the real termigate server on port 8888 with
config at `~/.config/termigate`. The drive must not touch either.
Override Make variables:

| Override          | Value                                  |
| ----------------- | -------------------------------------- |
| `CONTAINER_IMAGE` | `termigate:server-mobile-drive`        |
| `CONTAINER_PORT`  | `8889` (or any free non-8888)          |
| `CONFIG_DIR`      | `/tmp/termigate-server-mobile-drive`   |

The container has tmux installed inside it and runs its own internal
tmux daemon — the sessions you create during the drive live inside
the container, not on the host.

If the chosen port is already in use, pick another free one and
record it in the report.

## Step 1 — Build and run the container

From the repo root:

```bash
mkdir -p /tmp/termigate-server-mobile-drive
make build-container CONTAINER_IMAGE=termigate:server-mobile-drive
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  make run-container \
    CONTAINER_IMAGE=termigate:server-mobile-drive \
    CONTAINER_PORT=8889 \
    CONFIG_DIR=/tmp/termigate-server-mobile-drive
```

Run `make run-container` in the background (Bash
`run_in_background: true`). Save the SECRET_KEY_BASE to the report so
the run is reproducible.

Poll `http://127.0.0.1:8889/healthz` until it returns 200 (timeout
60s). Use the literal `127.0.0.1` rather than `localhost` — rootless
podman binds the published port to IPv4 only, but on hosts where
`localhost` resolves to `::1` first the request fails with
"Connection reset by peer" before retrying IPv4. If the healthcheck
never passes, capture the last 60 lines of container logs
(`podman logs termigate`) into a `## Setup failures` section and abort.

Use context-mode tools for `make build-container` and `podman logs` —
both produce more than 20 lines of output.

## Step 2 — Set up mobile emulation

Before navigating anywhere, configure the browser to emulate a phone.
Use Chrome DevTools MCP `emulate` (preferred — sets the user-agent,
DPR, mobile flag, and touch flag together) or `resize_page` as a
fallback for size-only changes.

The **primary device profile** for the drive is:

| Field             | Value                                                     |
| ----------------- | --------------------------------------------------------- |
| Name              | `iPhone SE (3rd gen)`                                     |
| Viewport          | `375 × 667`                                               |
| Device pixel ratio| `2`                                                       |
| Mobile            | `true`                                                    |
| Touch             | `true`                                                    |
| User-agent        | `Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1` |

Run the **entire happy-path** at this profile.

Additionally, **re-test layout-critical screens** at two more
viewports to catch breakpoint regressions:

| Profile           | Viewport     | Why                                          |
| ----------------- | ------------ | -------------------------------------------- |
| Small phone       | `320 × 568`  | Narrowest realistic width — text wrap, overflow. |
| Large phone       | `412 × 915`  | Pixel-class Android — taller, wider.         |

For each profile switch, take a fresh `take_screenshot` of the
session list, an attached terminal, and the settings page. Save under
`drive-artifacts/` with the profile name in the filename
(`session-list-iphone-se.png`, etc.).

## Step 3 — Drive the browser

Use the Chrome DevTools MCP tools (`mcp__plugin_chrome-devtools-mcp_*`)
for all browser actions. The `chrome-devtools-mcp:chrome-devtools`
skill can help if the MCP server isn't wired up yet.

For each navigation step, take a snapshot first
(`take_snapshot` for the accessibility tree, `take_screenshot` for
visual confirmation when the snapshot is ambiguous). Save screenshots
into `drive-artifacts/` and reference their paths in findings.

### Step 3a — Initial setup (mobile)

1. `new_page`, apply the iPhone SE emulation, then `navigate_page`
   to `http://127.0.0.1:8889/` (use the IPv4 literal, not
   `localhost`, for the same reason as the healthcheck). The server
   should redirect to `/setup` if no admin user yet exists.
2. `take_snapshot`, fill in admin username + a strong password,
   submit. Verify form inputs are full-width and the submit button is
   reachable without horizontal scroll.
3. Confirm the post-setup landing page renders cleanly at 375 px —
   no horizontal scrollbar, no clipped controls.
4. Visit `/settings` and capture an auth token if the UI offers one
   — record it in the report for later API checks.

Note any setup-flow oddities at mobile width (validation errors that
overflow, tap targets <44 × 44 CSS px, copy that wraps awkwardly,
inputs that trigger the wrong keyboard type) as findings.

### Step 3b — Auth happy path & failure path (mobile)

- Logout, then log back in with the same credentials.
- Try logging in with a wrong password — confirm the error is clearly
  surfaced and recoverable on a small screen (not pushed off-screen
  by the virtual keyboard).
- Try the password-visibility toggle (eye / eye-off icons from commit
  `83a451a`) — confirm the icon is at least 44 × 44 CSS px and both
  states render correctly at all three test viewports.

### Step 3c — Create and attach to a test session (mobile)

1. From the session list, create a session named `drive-test`. The
   server enforces `^[a-zA-Z0-9_-]+$`. Confirm the create form
   doesn't require horizontal scrolling.
2. Try a deliberately-invalid name (e.g. `drive test` with a space,
   or `drive.test`) — confirm the server rejects it with a clear,
   readable error at mobile width.
3. Attach to `drive-test`.
4. Wait for the terminal to render (xterm.js inside the LiveView).
   Confirm an initial prompt appears and that the terminal occupies
   the available viewport without overflow. Capture a screenshot.

### Step 3d — Verify the streaming pipeline (mobile)

Type the following commands one at a time. On mobile, dispatching
keys into a canvas-rendered xterm via the accessibility tree often
misses — prefer `evaluate_script` to focus the terminal element and
dispatch `keydown`/`textInput` events, or use `type_text` after
explicit focus. Wait for each command to render fully before moving
on. Capture a screenshot or accessibility-tree snapshot after each.

| Command                              | What it verifies                          |
| ------------------------------------ | ----------------------------------------- |
| `echo hello-termigate`               | Basic input → output streaming.           |
| `pwd`                                | Working directory; container shell works. |
| `printf '\\033[31mred\\033[0m\\n'`   | ANSI color rendering.                     |
| `for i in 1 2 3 4 5; do echo $i; sleep 0.2; done` | Streamed output, not buffered. |
| `seq 1 200`                          | Scrollback handling on a short viewport.  |
| `clear`                              | Screen clear.                             |
| `tput cols; tput lines`              | Terminal size negotiation at mobile width — `cols` should reflect the narrow viewport. |
| `cat`, type a few lines, then Ctrl-D | Stdin → tmux send-keys path. (For Ctrl-D, dispatch the key event via `evaluate_script`.) |

Pay extra attention to `tput cols` — the resize-to-mobile path is a
common regression source. Record the actual `cols`/`lines` reported
in the report.

If you have access to the auth token, also exercise the API/MCP
surface to confirm the token-based path works:

```bash
curl -fsSL -H "Authorization: Bearer <token>" \
  http://127.0.0.1:8889/healthz
```

Run any longer curl probes through context-mode tools.

### Step 3e — Lifecycle and edge cases (mobile)

- Detach from the session (browser back / nav). Re-attach. Confirm
  scrollback and prompt are preserved and that the terminal re-fits
  the viewport.
- Open the session in a second emulated mobile tab simultaneously —
  confirm output mirrors to both, and input from either tab reaches
  tmux.
- From the session list, kill the `drive-test` session. Confirm the
  list updates without a manual refresh (PubSub `{:sessions_changed}`
  on the `"sessions"` topic should drive this).
- Recreate the session and exercise mobile-relevant UX features:
  - **Quick Action Bar pills** (commit `1c9e29b`) — these are
    especially important on mobile. Tap each pill, verify the
    fade-edge / scroll affordance works under touch, and confirm
    horizontal scrolling reveals all pills without clipping.
  - **Terminal top-bar auto-hide timing** (commit `a963b6e`, now
    8s) — confirm it stays visible at least 8s before fading and
    that it can be re-summoned with a tap on mobile.
  - **Orientation change**: rotate the emulated device to landscape
    (`emulate` with swapped width/height) and confirm the layout
    reflows: terminal resizes, top-bar repositions, no clipping.
    Rotate back to portrait — confirm state survives.

### Step 3f — Multi-pane and settings (mobile)

- Visit `/multi-pane` (or whichever route the multi-pane LiveView
  is mounted on). Multi-pane on a 375 px viewport is inherently
  cramped — record whether the layout collapses to a stacked /
  carousel mode, or simply shrinks each pane. Split the pane, drive
  a command in each, confirm both stream independently and that
  pane focus indication is visible at mobile width.
- Visit `/settings`. Toggle each option, force-refresh the page,
  confirm persistence (server-side prefs) or that localStorage is
  used (client-side prefs) as designed. Confirm every toggle/control
  is at least 44 × 44 CSS px.

### Step 3g — Touch-target & responsive audit

For each top-level screen (login, session list, terminal, multi-pane,
settings), run a touch-target audit:

```js
// dispatched via evaluate_script
[...document.querySelectorAll('button, a, [role=button], input, [role=tab]')]
  .map(el => {
    const r = el.getBoundingClientRect();
    return { tag: el.tagName, text: el.innerText?.slice(0, 40), w: r.width, h: r.height };
  })
  .filter(x => x.w > 0 && x.h > 0 && (x.w < 44 || x.h < 44));
```

Any returned element is a finding (severity `minor` unless it's a
primary action, in which case `major`).

Also check for **horizontal overflow** on each screen:

```js
document.documentElement.scrollWidth > document.documentElement.clientWidth
```

If this returns `true` outside the terminal/scrollback area, that's a
finding.

### Step 3h — Console / network checks

After each major step, run:

- `mcp__plugin_chrome-devtools-mcp_chrome-devtools__list_console_messages`
  — record any new errors or unhandled rejections as findings.
- `mcp__plugin_chrome-devtools-mcp_chrome-devtools__list_network_requests`
  — flag any 4xx/5xx that aren't expected (e.g. failed /favicon are
  fine; failed /channels/* are not).

Filter long output through context-mode tools.

## Step 4 — Teardown

In order:

1. Close any open browser pages (`close_page`).
2. Stop the container: `podman stop termigate`.
3. Optionally remove the disposable config dir
   (`rm -rf /tmp/termigate-server-mobile-drive`) — ask the user first.

If teardown fails (e.g. container won't stop), record it as a finding
— leftover state is itself a result.

## Step 5 — Summary

Append a final `## Summary` section with:

- Total findings broken down by severity.
- A breakdown of mobile-specific findings (touch targets,
  horizontal overflow, keyboard / virtual-keyboard interactions,
  orientation, breakpoint regressions).
- Top 3 user-impacting issues on mobile.
- A "ready to ship on mobile" verdict (`yes` / `yes-with-caveats` /
  `no`), with a one-sentence justification.

Print the report path to the user when done. **Do not** commit the
report — the user decides.

## Failure handling

If any precondition gate fails (container won't build, healthcheck
won't pass, browser won't attach, mobile emulation won't apply, setup
form rejects valid input), stop and record the failure under
`## Setup failures` in the report. A partial drive past a broken
precondition produces misleading findings.

## Tooling notes

- Use context-mode tools (`ctx_batch_execute`, `ctx_execute`,
  `ctx_execute_file`) for any command with large output: `make
  build-container`, `podman logs`, `curl` probes against the API,
  console / network log dumps. Only short-output ops (mkdir, podman
  stop, podman ps single-line) belong in plain Bash.
- The Chrome DevTools MCP tools are the canonical way to drive the
  browser. Use `emulate` for full mobile profiles (UA + DPR + touch
  + size); use `resize_page` only when you need to flip orientation
  while keeping the rest of the profile.
- Take a `take_snapshot` (accessibility tree) before interactions;
  fall back to `take_screenshot` only when the snapshot is ambiguous
  — at mobile widths it often is, because controls overlap.
- For typing into the xterm.js terminal on a touch profile, prefer
  `evaluate_script` to focus the terminal and dispatch keyboard
  events. xterm renders into a canvas, so accessibility-tree clicks
  may miss, and the touch flag changes how some events route.
