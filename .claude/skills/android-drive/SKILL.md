---
name: android-drive
description: End-to-end Android app drive test for termigate. Builds and runs the prod container in isolation from the host's termigate, brings up an Android emulator, builds & installs the debug APK, logs the app in, exercises every surface, and writes findings to a Markdown report. Trigger with `/android-drive [REPORT.md]`. With no argument, writes to `archived-docs/ANDROID_DRIVE_yyyy-mm-dd.md` at the repo root using today's date.
---

# Android drive test

End-to-end exercise of the termigate Android app against a freshly
built production container, with all findings recorded to a Markdown
report file.

## Target report file

The path to the report file is the skill argument (for example,
`/android-drive my-report.md` writes findings to `my-report.md`).

If no argument is supplied, default to `archived-docs/ANDROID_DRIVE_yyyy-mm-dd.md`
at the repo root, where `yyyy-mm-dd` is today's date (compute with
`date +%Y-%m-%d`). Resolve relative paths from the repo root.

If the file already exists, ask the user whether to overwrite, append
to, or pick a new path before proceeding.

Initialize the file at the start of the run with a header that
records:

- The drive date and time.
- The container image tag and host port used.
- The chosen AVD and emulator serial.
- The APK path.
- The admin credentials and auth token used (so the user can audit
  the run).

Then add an empty `## Findings` section. **Append findings as you
discover them, not at the end.** Each finding entry should include:

- Short title.
- Severity: `blocker`, `major`, `minor`, or `nit`.
- Numbered steps to reproduce.
- Expected vs. actual behavior.
- Path to a screenshot if one was captured (use
  `android screen capture` and save into a `drive-artifacts/` dir
  alongside the report).

## Isolate the container from the host's termigate

The user typically runs the real termigate server on the host, on
port 8888, with config at `~/.config/termigate`. The drive test must
not touch either. Override the Makefile variables so the container
runs on its own port and config dir:

| Override          | Value                              |
| ----------------- | ---------------------------------- |
| `CONTAINER_IMAGE` | `termigate:android-drive`          |
| `CONTAINER_PORT`  | `8889` (or any free non-8888 port) |
| `CONFIG_DIR`      | `/tmp/termigate-android-drive`     |

The container has tmux installed inside it and runs its own tmux
daemon — the server inside the container talks only to that internal
tmux, never to the host's tmux sessions or to the host's running
termigate. Both the browser setup and the Android app connect to
`localhost:<CONTAINER_PORT>` on the host, which forwards into the
container.

If the chosen port is already in use, pick another free port and
record it in the report.

## Step 1 — Build and run the container

From the repo root:

```bash
mkdir -p /tmp/termigate-android-drive
make build-container CONTAINER_IMAGE=termigate:android-drive
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  make run-container \
    CONTAINER_IMAGE=termigate:android-drive \
    CONTAINER_PORT=8889 \
    CONFIG_DIR=/tmp/termigate-android-drive
```

Run `make run-container` in the background (Bash
`run_in_background: true`) so the rest of the drive can proceed.
Save the SECRET_KEY_BASE to the report so the run is reproducible.

Poll `http://localhost:8889/healthz` until it returns 200 (timeout
60s). If the healthcheck never passes, capture the last 60 lines of
container logs (`podman logs termigate`) into the report under
`## Setup failures` and abort.

## Step 2 — Browser-driven initial setup

Use the Chrome DevTools MCP tools (preferred) to drive the setup
flow. The `chrome-devtools-mcp:chrome-devtools` skill can help if
the MCP server isn't already attached to a browser.

1. `new_page` then `navigate_page` to `http://localhost:8889/`. The
   server should redirect to `/setup` if no admin user yet exists.
2. `take_snapshot` and read the form fields. Fill in the admin
   username and a strong password. Record both in the report.
3. Submit and confirm the resulting page is the authenticated
   session list (or whichever post-setup landing page the server
   uses).
4. Visit `/settings` and capture/copy an auth token if the server
   exposes one — record the token in the report. Otherwise, plan to
   log in by username + password from the Android app.

Note any setup-flow oddities (validation errors, missing copy,
redirect loops, layout issues) as findings as you go.

## Step 3 — Start the emulator with the `android` CLI

1. List available AVDs: `android emulator list`. Pick the most
   recent / highest-API AVD. Record the chosen AVD name.
2. Start it in the background:
   ```bash
   android emulator start <avd>
   ```
   Run with `run_in_background: true`. Save the resulting PID so
   teardown can stop it cleanly.
3. Wait for adb to register it as `device`:
   - Poll `adb devices` until exactly one device shows status
     `device` (not `offline`). Timeout 120s.
   - Then poll `adb -s <serial> shell getprop sys.boot_completed`
     until it returns `1`. Timeout 180s.
4. If either poll times out, capture `adb devices -l` and the last
   60 lines of emulator output to the report and abort.

Verify reachability: `adb -s <serial> shell echo ok` must print
`ok`. Do not proceed past this gate until adb is confirmed working.

## Step 4 — Wire up host ↔ emulator connectivity

The emulator can reach the host two ways. Try them in order and use
whichever the app accepts cleanly. Record which option worked.

1. **adb reverse** — makes the emulator's `localhost:8889` map to
   the host's `localhost:8889`:
   ```bash
   adb -s <serial> reverse tcp:8889 tcp:8889
   ```
   Then in the app, use server URL `http://localhost:8889`.
2. **Magic loopback** — the emulator can reach the host directly at
   `10.0.2.2`. Use server URL `http://10.0.2.2:8889`.

Confirm with: `adb -s <serial> shell curl -s -o /dev/null -w '%{http_code}' http://localhost:8889/healthz`
should return `200` (option 1) or use `10.0.2.2` for option 2.

## Step 5 — Build and install the debug APK

```bash
make android                # builds debug APK via gradle
make android-install-debug  # uninstalls any prior copy, installs fresh
```

Record the APK path
(`android/app/build/outputs/apk/debug/app-debug.apk`) and its SHA-256
in the report.

If the build fails, capture the last 80 lines of gradle output to
the report under `## Setup failures` and abort. Do not proceed with
a stale APK.

## Step 6 — Launch the app

Either:

```bash
adb -s <serial> shell monkey -p org.tamx.termigate.debug \
  -c android.intent.category.LAUNCHER 1
```

or:

```bash
android run --apks=android/app/build/outputs/apk/debug/app-debug.apk \
  --device=<serial>
```

After launch, capture an `android screen capture` screenshot of the
landing screen and save into `drive-artifacts/01-launch.png`.

For UI introspection during the drive, prefer in this order:

1. `android layout` — fastest, returns the UI tree as text.
2. `mcp__mobile-mcp__mobile_list_elements_on_screen` — when the
   layout tree is ambiguous.
3. `mcp__mobile-mcp__mobile_take_screenshot` — when a visual is
   clearer than text.

For tap/swipe/type, use either the mobile-mcp tools or
`adb shell input` directly — whichever is more reliable for the
target widget.

## Step 7 — Log in

Enter the server URL from Step 4, the admin username and password
(or the token) from Step 2. Confirm the session list loads.

Record any input-handling annoyances (URL field rejecting schemes,
keyboard hiding the submit button, autofill misbehaving) as
findings.

## Step 8 — Exercise the app broadly

Walk every surface the app exposes. Use the headings below as a
checklist; adapt to what's actually present in the app.

### Auth

- Valid login.
- Invalid login (wrong password) — error visible and recoverable.
- Logout, then re-login.
- Token-based login (if the app supports it).
- Kill app, re-open, confirm session restore behavior.

### Session list

- List loads and refreshes.
- Create a new session — record the accepted name pattern. Try a
  name with disallowed characters; the server enforces
  `^[a-zA-Z0-9_-]+$`, so confirm the app surfaces a clear error.
- Kill a session.
- Switch between sessions.

### Terminal view

- Typing prints to the pane.
- Special keys: arrow keys, Tab, Esc, Ctrl combinations, function
  keys.
- Copy / paste in both directions.
- Scrollback works and isn't lost on rotation.
- Font / size adjustments persist.
- Terminal resizes correctly when the window changes (rotation,
  keyboard, multi-pane split).

### Multi-pane

- Split horizontally and vertically.
- Navigate between panes.
- Resize panes.
- Close a pane.

### Settings

- Every toggle / field. Change a value, force-stop the app,
  re-open, confirm persistence.
- Test invalid inputs (out-of-range numbers, empty strings) — the
  app should refuse cleanly.

### Quick action bar

- Tap each pill; confirm it inserts the right key sequence.
- Verify the fade-edge / horizontal-scroll affordance from the
  recent commit `1c9e29b`.

### Connectivity & lifecycle

- Background and foreground the app — confirm the pane reconnects
  without losing scrollback.
- Toggle airplane mode on then off — confirm graceful reconnect.
- Rotate portrait ↔ landscape during a live session — pane should
  not be lost.
- `podman stop termigate` mid-session — app should surface a clear
  disconnection. Restart it (`podman start termigate`) and confirm
  reconnect.

### Crashes / ANRs

After each surface, dump recent errors:

```bash
adb -s <serial> logcat -d -t '2 minutes ago' '*:E' '*:W' \
  | grep -E 'org\.tamx\.termigate|FATAL|AndroidRuntime|ANR'
```

Pipe through context-mode tools for filtering (output is large).
Record any new crashes, ANRs, or red-flag warnings as findings.

## Step 9 — Teardown

In order:

1. `adb -s <serial> uninstall org.tamx.termigate.debug`.
2. Remove any port forwards: `adb -s <serial> reverse --remove-all`.
3. Stop the emulator: `android emulator stop <avd>` (or kill the
   saved PID).
4. Stop the container: `podman stop termigate`.
5. Optionally remove the disposable config dir
   (`rm -rf /tmp/termigate-android-drive`) — ask the user first.

If any teardown step fails, record it in the report — leftover
state is itself a finding.

## Step 10 — Summary

Append a final `## Summary` section with:

- Total findings broken down by severity.
- Top 3 user-impacting issues.
- A "ready to ship" verdict (`yes` / `yes-with-caveats` / `no`),
  with one-sentence justification.

Print the report path to the user when done. **Do not** commit the
report — the user decides whether to keep it.

## Failure handling

If any precondition gate fails (container won't build, healthcheck
won't pass, no AVDs, emulator never boots, APK won't install), stop
and record the failure under `## Setup failures` in the report. Do
not soldier on with a broken environment — partial drives produce
misleading findings.

## Tooling notes

- Use context-mode tools (`ctx_batch_execute`, `ctx_execute`,
  `ctx_execute_file`) for any command with large output: gradle
  builds, podman build, podman logs, logcat, layout dumps. Only
  short-output ops (mkdir, podman stop, single-line adb shell) belong
  in plain Bash.
- The `android` CLI and the `mcp__mobile-mcp__*` tools are
  interchangeable for most device operations — pick whichever is more
  reliable for the specific action. The android CLI is faster for
  `screen capture` and `layout`; mobile-mcp is friendlier for taps by
  element.
- The `chrome-devtools-mcp:chrome-devtools` skill is the canonical
  way to drive the browser steps — invoke it if the MCP server isn't
  already wired up.
