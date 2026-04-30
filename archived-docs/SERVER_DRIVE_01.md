# Server drive — 2026-04-30

| Field             | Value                                                |
| ----------------- | ---------------------------------------------------- |
| Drive started     | 2026-04-30 08:32:56 MDT                              |
| Container image   | `termigate:server-drive`                             |
| Host port         | `8889` (host's real termigate occupies 8888)         |
| Config dir        | `/tmp/termigate-server-drive`                        |
| Admin user        | `driveadmin`                                         |
| Admin password    | `Drive!Test-2026-04-30` (disposable, container-only) |
| Secret key base   | `y3I43GQ/qdRgVh0ekmHAd2Nh9TbqqQ8fKfR1g51PfZ0iaCdN/o5u8TC3VJY4Ekj1` |
| Browser           | Chromium via Chrome DevTools MCP                     |
| Artifacts dir     | `drive-artifacts/`                                   |

## Setup notes

- Healthcheck on `localhost:8889` over IPv6 (`::1`) resets the
  connection ("Connection reset by peer"); IPv4 (`127.0.0.1:8889`)
  is healthy. This is a known rootless-podman quirk with
  slirp4netns port forwarding — not a termigate issue. The browser
  drive used `http://127.0.0.1:8889/` to avoid the IPv6 path.
- Container starts with no admin user — server logs warn:
  `Listening on 0.0.0.0 with no authentication configured. Set up
  auth via 'cd server && mix termigate.setup' or set
  TERMIGATE_AUTH_TOKEN.` First browser hit correctly redirected
  to `/setup`.

## Streaming pipeline ✓ (no finding — captured for the record)

All pipeline checks against the `drive-test` pane succeeded:

| Command                                | Verified                               |
| -------------------------------------- | -------------------------------------- |
| `echo hello-termigate`                 | basic input → output streaming         |
| `pwd` → `/`                            | shell alive, working dir               |
| `printf '\033[31mred\033[0m\n'`        | ANSI red rendered (`xterm-fg-1` class) |
| `for i in 1..5; do echo $i; sleep 0.2` | output streamed, not buffered          |
| `seq 1 200`                            | scrollback up to 200 lines             |
| `clear`                                | full screen clear                      |
| `tput cols; tput lines` → `120 40`     | terminal size negotiation              |
| `cat` ⏎ two lines ⏎ Ctrl-D             | stdin → tmux send-keys path            |
| Quick Action pill "Disk Usage"         | `df -h` typed and run automatically    |
| Multi-tab mirroring                    | output from tab A appears in tab B and vice-versa |
| Multi-pane (split horizontally)        | each pane streams independently        |
| Detach + reattach                      | scrollback preserved across nav        |
| Kill from session list                 | list auto-updates via PubSub (no refresh) |
| Settings → Font Size 14 → 18           | persists across reload, applies to xterm |

Screenshots: `drive-artifacts/05-attached-drive-test.png`,
`drive-artifacts/06-pwd-and-color.png`,
`drive-artifacts/07-quick-action-disk-usage.png`,
`drive-artifacts/08-multi-pane-split.png`.

## Findings

### Wrong-password attempts produce no error message

- **Severity:** major
- **Repro:**
    1. Log out, land on `/login`.
    2. Enter username `driveadmin` and a wrong password.
    3. Submit "Sign in".
- **Expected:** the page shows a clearly visible error such as
  "Invalid username or password." (server already calls
  `put_flash(:error, "Invalid username or password.")` in
  `auth_controller.ex:66`).
- **Actual:** server redirects back to `/login`; the form is
  cleared but no error is rendered. The flash is dropped because
  neither `auth_live.ex` nor the root layout
  (`components/layouts/root.html.heex`) calls
  `<.flash_group flash={@flash} />`. Users get zero feedback after
  a failed login — indistinguishable from a network blip — so
  they retype the same wrong password without realizing it's
  rejected.
- **Fix:** add `<.flash_group flash={@flash} />` to `auth_live.ex`'s
  `render/1` (or to `root.html.heex` so every page gets it).
- **Screenshot:** `drive-artifacts/03-login-after-wrong-password-no-error.png`.

### Theme dropdown only re-themes the terminal, not the page chrome

- **Severity:** major
- **Repro:**
    1. Log in, visit `/settings` → TERMINAL APPEARANCE.
    2. Change **Theme** from "Dark" to "Light", click "Save".
    3. Reload (or hard-reload) any page — `/settings`, `/`, or
       `/sessions/<name>/windows/0`.
- **Expected:** the entire UI re-skins to the Light DaisyUI theme:
  light page background, light cards, light buttons.
- **Actual:** the saved theme survives a reload (server-side YAML
  persistence works), but `<html data-theme>` is **hardcoded**
  `"dark"` in
  `server/lib/termigate_web/components/layouts/root.html.heex:2`,
  so DaisyUI keeps painting the page in dark colors. Only the
  xterm.js terminal canvas honors the new theme (via
  `terminal_hook.js`'s `resolveTheme(prefs)`); the login page,
  session list, settings page, multi-pane chrome, and modals all
  remain dark forever. The Theme dropdown is effectively
  decorative for everything except inside the terminal canvas.
- **Fix:** bind `data-theme` on `<html>` to the user's saved theme
  (read it from the LiveView assigns or a `<.live_session>`
  assign), and update it on theme change.

### After Create Account, user must log in again manually

- **Severity:** minor
- **Repro:**
    1. Complete the setup form at `/setup` with valid credentials.
    2. Submit "Create Account".
- **Expected:** server creates the admin user and lands them on
  the session list (already authenticated). They just proved
  possession of the password seconds ago.
- **Actual:** server redirects to `/login` and asks them to type
  the same credentials again. Adds friction with no security
  benefit on a freshly-created account.

### Direct GET to `/logout` returns 404

- **Severity:** minor
- **Repro:**
    1. While logged in, paste `http://127.0.0.1:8889/logout` into
       the address bar (e.g. from a bookmark) and press Enter.
- **Expected:** either log out the user or show a clear page
  ("Use the Log out button" or a confirm form). Even the
  standard Phoenix pattern of also accepting GET would work.
- **Actual:** plain `Not Found` 404 page. The session-list
  Log out link is a `data-method="delete"` Phoenix anchor that
  uses CSRF + JS interception, so address-bar / middle-click /
  bookmark navigation never logs the user out and just shows a
  confusing 404.

### Settings page exposes no API-token UI

- **Severity:** minor
- **Repro:**
    1. Log in as admin, visit `/settings`.
- **Expected:** a clearly labeled section to view/rotate the
  `TERMIGATE_AUTH_TOKEN` (or generate per-app tokens) — the API,
  channels, and Android app all use bearer tokens.
- **Actual:** the only auth-related controls are session duration
  and change-password. Token-based access is environment-variable
  only. Operators have to know to set `TERMIGATE_AUTH_TOKEN` at
  container start with no in-app affordance.

### Killed-session tabs show empty pane state but no kill notification

- **Severity:** minor
- **Repro:**
    1. Attach to `drive-test` (one pane open).
    2. In a second tab, kill the session via the disclosure
       menu's "Kill Session" → confirm modal.
    3. Switch back to the first tab.
- **Expected:** a flash / banner like "Session was killed" with a
  "Back to sessions" button, ideally redirecting automatically.
- **Actual:** the page silently re-renders to "click a pane to
  activate / No panes in this window / Back to Sessions" — but
  the URL and tab title still say `drive-test:0`, and there is
  no explicit notification that the session no longer exists.
  Easy to mistake for a transient render glitch.

### Setup form pre-fills username with `root`

- **Severity:** nit
- **Repro:**
    1. Start a fresh container with no admin user.
    2. Navigate to `http://127.0.0.1:8889/`.
    3. Server redirects to `/setup`; the **Username** field is
       pre-populated with `root` and focused.
- **Expected:** an empty username field (or a sensible placeholder)
  so users actively pick a name; defaulting to `root` nudges them
  toward a generic account that's a brute-force target.
- **Actual:** the field is pre-filled with `root` and focused, so
  a hurried user can submit `root` + any password without
  thinking.
- **Screenshot:** `drive-artifacts/01-setup-form.png`.

### Console reports unnamed form fields (a11y)

- **Severity:** nit
- **Repro:** load `/sessions/<name>/windows/0` and open DevTools.
- **Expected:** all `<input>`/`<select>`/`<textarea>` elements
  have `id` or `name`.
- **Actual:** Chrome DevTools issue: "A form field element should
  have an id or name attribute (count: 2)" on the multi-pane
  page. Likely the two terminal-input shadow inputs xterm.js
  inserts; either give them `name`/`aria-label` or
  `data-no-autofill` to silence the warning.

## Summary

| Severity | Count |
| -------- | ----- |
| blocker  | 0     |
| major    | 2     |
| minor    | 4     |
| nit      | 2     |

### Top user-impacting issues

1. **Wrong-password attempts produce no error message** (major) —
   `auth_live.ex` doesn't render `<.flash_group />`, so the
   "Invalid username or password." flash from
   `auth_controller.ex:66` is silently swallowed. Users get zero
   feedback on a failed login.
2. **Theme dropdown only re-themes the terminal canvas** (major) —
   `<html data-theme>` is hardcoded `"dark"` in
   `components/layouts/root.html.heex:2`, so saved theme prefs
   only affect xterm.js, not the page chrome.
3. **`GET /logout` returns 404** (minor) — the Phoenix
   `data-method="delete"` link works for in-app clicks but
   bookmarks / address-bar / middle-click navigation hit a bare
   404, which is confusing.

### Verdict

**yes-with-caveats** — the streaming pipeline (input → tmux,
output → xterm, scrollback, multi-tab mirroring, multi-pane,
ANSI colors, terminal size, stdin EOF) is solid and PubSub
session-list updates work in real time, but the two **major**
findings (silent failed-login and dead Theme dropdown) are
user-visible regressions that should land a fix before the next
release tag.
