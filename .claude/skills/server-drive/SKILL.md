---
name: server-drive
description: End-to-end browser drive test of the termigate server. Builds and runs the prod container in isolation from the host's termigate, drives it via the Chrome DevTools MCP browser, completes initial setup, creates a test session, attaches to it, runs commands to verify the streaming pipeline, and writes findings to a Markdown report. Trigger with `/server-drive [REPORT.md]`. With no argument, writes to `archived-docs/SERVER_DRIVE_yyyy-mm-dd.md` at the repo root using today's date.
---

# Server drive test

End-to-end exercise of the termigate server in its production
container, driven through the browser with the Chrome DevTools MCP
tools. All findings go into a Markdown report file.

## Target report file

The path is the skill argument (e.g. `/server-drive my-report.md`).

If no argument is given, default to `archived-docs/SERVER_DRIVE_yyyy-mm-dd.md` at
the repo root, where `yyyy-mm-dd` is today's date (compute with
`date +%Y-%m-%d`). Resolve relative paths from the repo root.

If the file already exists, ask the user whether to overwrite, append,
or pick a different path before continuing.

Initialize the file at the start with a header recording:

- Drive date and time.
- Container image tag and host port.
- Admin credentials used.
- Browser used for the drive (Chromium via Chrome DevTools MCP).

Then add an empty `## Findings` section. **Append findings as you
discover them, not at the end.** Each entry includes:

- Short title.
- Severity: `blocker`, `major`, `minor`, or `nit`.
- Numbered repro steps.
- Expected vs. actual behavior.
- Screenshot path if captured (save under `drive-artifacts/`).

## Isolate from the host's termigate

The host typically runs the real termigate server on port 8888 with
config at `~/.config/termigate`. The drive must not touch either.
Override Make variables:

| Override          | Value                            |
| ----------------- | -------------------------------- |
| `CONTAINER_IMAGE` | `termigate:server-drive`         |
| `CONTAINER_PORT`  | `8889` (or any free non-8888)    |
| `CONFIG_DIR`      | `/tmp/termigate-server-drive`    |

The container has tmux installed inside it and runs its own internal
tmux daemon — the sessions you create during the drive live inside
the container, not on the host.

If the chosen port is already in use, pick another free one and
record it in the report.

## Step 1 — Build and run the container

From the repo root:

```bash
mkdir -p /tmp/termigate-server-drive
make build-container CONTAINER_IMAGE=termigate:server-drive
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  make run-container \
    CONTAINER_IMAGE=termigate:server-drive \
    CONTAINER_PORT=8889 \
    CONFIG_DIR=/tmp/termigate-server-drive
```

Run `make run-container` in the background (Bash
`run_in_background: true`). Save the SECRET_KEY_BASE to the report so
the run is reproducible.

Poll `http://localhost:8889/healthz` until it returns 200 (timeout
60s). If the healthcheck never passes, capture the last 60 lines of
container logs (`podman logs termigate`) into a `## Setup failures`
section and abort.

Use context-mode tools for `make build-container` and `podman logs` —
both produce more than 20 lines of output.

## Step 2 — Drive the browser

Use the Chrome DevTools MCP tools (`mcp__plugin_chrome-devtools-mcp_*`)
for all browser actions. The `chrome-devtools-mcp:chrome-devtools`
skill can help if the MCP server isn't wired up yet.

For each navigation step, take a snapshot first
(`take_snapshot` for the accessibility tree, `take_screenshot` for
visual confirmation when the snapshot is ambiguous). Save screenshots
into `drive-artifacts/` and reference their paths in findings.

### Step 2a — Initial setup

1. `new_page` then `navigate_page` to `http://localhost:8889/`. The
   server should redirect to `/setup` if no admin user yet exists.
2. `take_snapshot`, fill in admin username + a strong password, submit.
3. Confirm the post-setup landing page (session list, or whichever
   page the server uses).
4. Visit `/settings` and capture an auth token if the UI offers one
   — record it in the report for later API checks.

Note any setup-flow oddities (validation errors, missing copy,
redirect loops, layout glitches) as findings.

### Step 2b — Auth happy path & failure path

- Logout, then log back in with the same credentials.
- Try logging in with a wrong password — confirm the error is clearly
  surfaced and recoverable.
- Try the new password-visibility toggle (the recent commit `83a451a`
  uses eye / eye-off icons) — confirm both states render and toggle
  correctly.

### Step 2c — Create and attach to a test session

1. From the session list, create a session named `drive-test`. The
   server enforces `^[a-zA-Z0-9_-]+$`.
2. Try a deliberately-invalid name (e.g. `drive test` with a space,
   or `drive.test`) — confirm the server rejects it with a clear
   error.
3. Attach to `drive-test`.
4. Wait for the terminal to render (xterm.js inside the LiveView).
   Confirm an initial prompt appears — capture a screenshot for the
   report.

### Step 2d — Verify the streaming pipeline

Type the following commands one at a time. Wait for each to render
fully before moving on. Capture a screenshot or accessibility-tree
snapshot after each.

| Command                              | What it verifies                          |
| ------------------------------------ | ----------------------------------------- |
| `echo hello-termigate`               | Basic input → output streaming.           |
| `pwd`                                | Working directory; container shell works. |
| `printf '\\033[31mred\\033[0m\\n'`   | ANSI color rendering.                     |
| `for i in 1 2 3 4 5; do echo $i; sleep 0.2; done` | Streamed output, not buffered. |
| `seq 1 200`                          | Scrollback handling.                      |
| `clear`                              | Screen clear.                             |
| `tput cols; tput lines`              | Terminal size negotiation.                |
| `cat`, type a few lines, then Ctrl-D | Stdin → tmux send-keys path.              |

If you have access to the auth token, also exercise the API/MCP
surface to confirm the token-based path works:

```bash
curl -fsSL -H "Authorization: Bearer <token>" \
  http://localhost:8889/healthz
```

Run any longer curl probes through context-mode tools.

### Step 2e — Lifecycle and edge cases

- Detach from the session (browser back / nav). Re-attach. Confirm
  scrollback and prompt are preserved.
- Open the session in a second browser tab simultaneously — confirm
  output mirrors to both, and input from either tab reaches tmux.
- From the session list, kill the `drive-test` session. Confirm the
  list updates without a manual refresh (PubSub `{:sessions_changed}`
  on the `"sessions"` topic should drive this).
- Recreate the session and try the recent commits' UX features:
  - Quick Action Bar pills (commit `1c9e29b`) — tap each, verify the
    fade-edge / scroll affordance.
  - Terminal top-bar auto-hide timing (commit `a963b6e`, now 8s) —
    confirm it stays visible at least 8s before fading.

### Step 2f — Multi-pane and settings

- Visit `/multi-pane` (or whichever route the multi-pane LiveView
  is mounted on). Split the pane, drive a command in each, confirm
  both stream independently.
- Visit `/settings`. Toggle each option, force-refresh the page,
  confirm persistence (server-side prefs) or that localStorage is
  used (client-side prefs) as designed.

### Step 2g — Console / network checks

After each major step, run:

- `mcp__plugin_chrome-devtools-mcp_chrome-devtools__list_console_messages`
  — record any new errors or unhandled rejections as findings.
- `mcp__plugin_chrome-devtools-mcp_chrome-devtools__list_network_requests`
  — flag any 4xx/5xx that aren't expected (e.g. failed /favicon are
  fine; failed /channels/* are not).

Filter long output through context-mode tools.

## Step 3 — Teardown

In order:

1. Close any open browser pages (`close_page`).
2. Stop the container: `podman stop termigate`.
3. Optionally remove the disposable config dir
   (`rm -rf /tmp/termigate-server-drive`) — ask the user first.

If teardown fails (e.g. container won't stop), record it as a finding
— leftover state is itself a result.

## Step 4 — Summary

Append a final `## Summary` section with:

- Total findings broken down by severity.
- Top 3 user-impacting issues.
- A "ready to ship" verdict (`yes` / `yes-with-caveats` / `no`),
  with a one-sentence justification.

Print the report path to the user when done. **Do not** commit the
report — the user decides.

## Failure handling

If any precondition gate fails (container won't build, healthcheck
won't pass, browser won't attach, setup form rejects valid input),
stop and record the failure under `## Setup failures` in the report.
A partial drive past a broken precondition produces misleading
findings.

## Tooling notes

- Use context-mode tools (`ctx_batch_execute`, `ctx_execute`,
  `ctx_execute_file`) for any command with large output: `make
  build-container`, `podman logs`, `curl` probes against the API,
  console / network log dumps. Only short-output ops (mkdir, podman
  stop, podman ps single-line) belong in plain Bash.
- The Chrome DevTools MCP tools are the canonical way to drive the
  browser. Take a `take_snapshot` (accessibility tree) before
  interactions; fall back to `take_screenshot` only when the
  snapshot is ambiguous.
- For typing into the xterm.js terminal, prefer `evaluate_script`
  to dispatch keyboard events into the focused terminal element if
  `type_text` doesn't reach it cleanly — xterm renders into a
  canvas, so accessibility-tree clicks may miss.
