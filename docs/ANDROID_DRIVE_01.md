# ANDROID_DRIVE_01

Drive log of the Android client against a freshly built **prod container**
(`make build-container` + `podman run` on host port 9999, isolated config dir,
no host-tmux mount). Tested on the `medium_phone` AVD (Android 16, 1080x2400,
Pixel-style emulator) using the `org.tamx.termigate.debug` build from
`make android-install-debug`.

Date: 2026-04-28 · Build SHA: `a386f28` (main, plus untracked drive log files).

## Fix progress

- [x] Bug 1 — `force_ssl` excludes only `localhost`/`127.0.0.1`, breaks Android emulator (and LAN access)
- [x] Bug 2 — Tapping the terminal does not raise the soft keyboard
- [x] Bug 3 — Terminal viewport renders the buffer at the top *and* at the bottom of the screen
- [ ] Bug 4 — Terminal viewport is sized to the 80×24 cell grid in pixels, not to the available screen
- [ ] Bug 5 — Top bar auto-hides too aggressively, removing the only Back / Fit / Keyboard affordances
- [ ] Bug 6 — Quick Action pill bar shows ~3 of 5 configured actions; not obvious it scrolls
- [ ] Bug 7 — "Show" toggle on the Password field is plain text, not a real button
- [ ] Bug 8 — `EditText` fields on Login/Settings dialogs have empty `text`/`label` until focused
- [ ] Bug 9 — Login screen has no logo (web has the termigate green-leaf image)
- [ ] Bug 10 — Tapping anywhere on a session row in the list does nothing; only chevron expands

## Setup

```
make build-container                                  # cached
SECRET_KEY_BASE=$(openssl rand -base64 48) \
  podman run -d --rm --name termigate-drive \
  -p 9999:8888 \
  -e SECRET_KEY_BASE \
  -e TERMIGATE_CHECK_ORIGIN=false \
  -v /tmp/termigate-drive/config:/root/.config/termigate:Z \
  localhost/termigate:latest

android emulator start medium_phone &
adb -s emulator-5554 reverse tcp:8888 tcp:9999    # see Bug 1
make android-install-debug
```

Initial setup completed via the desktop browser (Chrome DevTools MCP) at
`http://127.0.0.1:9999/setup` — created user `drive`/`drivepass123`. After
that, the Android app at `org.tamx.termigate.debug` was launched on the
emulator.

---

## Bugs

### Bug 1 — `force_ssl` excludes only `localhost`/`127.0.0.1`, breaks Android emulator (and LAN access)

**Severity:** High — the Android app cannot connect to the prod container by
its emulator-host address (`10.0.2.2`) and any phone on a LAN cannot connect
by the host's LAN IP either.

**Reproduce:**
1. Run the prod container exposing HTTP only (no TLS terminator in front).
2. From the Android app, set Server URL to `http://10.0.2.2:9999` (the
   standard emulator-to-host address) and tap Connect.
3. The app surfaces "Could not connect to server".

**Server logs show the cause:**

```
[info] Plug.SSL is redirecting GET /api/sessions to https://localhost with status 301
```

**Root cause:** `server/config/prod.exs:14`

```elixir
config :termigate, TermigateWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

`force_ssl` is set at compile time and only excludes the literal hosts
`localhost`/`127.0.0.1`. Any other Host header — `10.0.2.2:9999` from the
Android emulator, or `192.168.x.y:9999` from a real phone on the LAN —
triggers a 301 to `https://<host>` (note: bare `https://localhost`, since the
host gets rewritten to the configured `url[host]`, which collapses the port).
The container only listens on HTTP, so the redirect is unreachable either
way, and the OkHttp/Ktor stack in the Android app reports a connect failure.

This conflicts with the deployment story documented in `README.md`
("By default … the container is reachable from any browser the moment it
starts"). The runtime `check_origin` was made permissive on purpose for
exactly this reason; `force_ssl` was not.

**Workaround used during the drive:**
`adb -s emulator-5554 reverse tcp:8888 tcp:9999` so the app can talk to
`http://localhost:8888`, which the exclude list whitelists.

**Suggested fix options:**
- Make `force_ssl` runtime-configurable (e.g., `TERMIGATE_FORCE_SSL=false`)
  alongside the existing `TERMIGATE_CHECK_ORIGIN`. Default to *off* unless
  `PHX_HOST` is explicitly set, mirroring the `check_origin` policy.
- Or expand the exclude list to `["localhost", "127.0.0.1", "10.0.2.2"]`
  and document that LAN deployments must front the container with TLS.
- Or have the runtime config set `force_ssl: false` when `PHX_HOST` is unset.

---

### Bug 2 — Tapping the terminal does not raise the soft keyboard

**Severity:** High — there is no way to type free-form input into a tmux
pane from the Android app on this device. Quick Actions and predefined
output still flow, but interactive use (running `vim`, `htop`, `git`,
typing any command) is impossible without a hardware keyboard.

**Reproduce:**
1. Log in, expand `main`, tap on `bash · pane 0`.
2. Terminal connects (server logs `Terminal channel joined: main:0.0`).
3. Tap anywhere on the terminal viewport (single tap).
4. **Expected:** soft keyboard slides up, Special Key Toolbar appears above
   it (`Esc`/`Tab`/`Ctrl`/`Alt`/arrows/F-keys per
   `SpecialKeyToolbar.kt`).
5. **Actual:** nothing visible happens. The top bar does not toggle either.

**Diagnostic data:**

```
$ adb shell dumpsys input_method | grep -E 'mInputShown|mServedView'
mInputShown=false
mServedView=com.termux.view.TerminalView{… 0,0-640,408 …}
```

After a long-press the IME *registers* the TerminalView as `mServedView`
(InputConnection wired up), but `mInputShown` stays `false` — the IME never
animates in. `service call input_method 16` (force show) also leaves it
hidden. The single-tap is supposed to call `showKeyboard()` from
`onSingleTapUp` (see `terminal-lib`, used from `TerminalScreen.kt`), but
the soft input doesn't surface.

Because `SpecialKeyToolbar` is gated on `isKeyboardVisible`, the toolbar
also never appears, so there's no fallback path to send `Esc`/`Ctrl`/arrows
either. The user is stuck with whatever Quick Actions are pre-configured.

**Suggested investigation:**
- Verify `TerminalView.requestFocus()` is being called inside
  `onSingleTapUp` and that the view actually has focusable=true at that
  point (the Compose `BoxWithConstraints` wrapping it may be intercepting
  focus).
- Try calling `WindowInsetsControllerCompat.show(WindowInsetsCompat.Type.ime())`
  from the surrounding Compose code as a backup when the gesture fires.
- Confirm `android:windowSoftInputMode="adjustResize"` (already set in the
  manifest) is taking effect; the auto-hide top-bar logic shouldn't
  consume the tap before it reaches the TerminalView.

---

### Bug 3 — Terminal viewport renders the buffer at the top *and* at the bottom of the screen

**Severity:** Medium — confusing visual rendering; users see the same
prompt/output twice with a large empty band between them.

**Reproduce:**
1. Open any pane.
2. Trigger any output (e.g., the "Disk Usage" Quick Action runs `df -h`).
3. Observe the screen: the `df -h` output appears at ~y=190–322 *and again*
   at ~y=2050–2200, with a dark/empty band between.

**Diagnostic data:**
- `uiautomator dump` shows exactly one `ViewFactoryHolder` for the
  TerminalView at bounds `[0,169][640,577]` (640×408 px). There is no
  second TerminalView in the app's view hierarchy.
- The "second copy" at the bottom sits within the IME's reserved insets
  (`mInsetsHint=Insets{… bottom=883}` from `dumpsys window`) even though
  `mInputShown=false`.

**Hypothesis:** the IME service is rendering an "extracted text view" of
the TerminalView's `InputConnection` in its sleeping keyboard area, and
the InputConnection is exposing the visible terminal cells as its
extracted-text content. Likely tied to Bug 2 — once the soft keyboard
behaves correctly, the bottom render should disappear behind the keyboard
panel. Worth verifying with
`InputConnection.getExtractedText()` overrides in `TerminalView` (set
`UPDATE_EXTRACTED_TEXT_NONE` or override to return `null`).

---

### Bug 4 — Terminal viewport is sized to the 80×24 cell grid in pixels, not to the available screen

**Severity:** Medium — very visible: the terminal occupies a 640×408 px
rectangle in the top-left corner of a 1080×2400 device, with the rest of
the parent dark Box unused.

**Diagnostic data:** TerminalView bounds `[0,169][640,577]` on a 1080×2400
device. The Compose parent `BoxWithConstraints { … AndroidView … }` in
`TerminalScreen.kt` is full-size, but the inner TerminalView is sizing
itself to its 80×24 character grid at the chosen font size
(80 cols × ~8 px ≈ 640, 24 rows × ~17 px ≈ 408).

The comment in `TerminalScreen.kt` says: "the client never pushes a resize
based on its own view geometry. The session's emulator dims track tmux …
the only client-driven resize is the explicit 'Fit to screen width' action
in the top bar." That's a deliberate design decision, but the consequence
is that the *visible* terminal is tiny and there's no obvious top-bar
button to tap (top bar auto-hides; see Bug 5). Users have no way to know
that "Fit" exists.

**Suggested fixes:**
- Either auto-fit on first connect (initial screen-fill) and let users opt
  out, or expose the Fit button persistently (not behind the auto-hide
  top bar).
- At minimum, the AndroidView container should `MATCH_PARENT` so the dark
  background doesn't span the screen — the column-fill behavior in tmux
  would still control the cells, but at least the empty band wouldn't
  exist.

---

### Bug 5 — Top bar auto-hides too aggressively, removing the only Back / Fit / Keyboard affordances

**Severity:** Medium — combined with Bugs 2 and 4, the user can find
themselves on the terminal screen with **no visible way back**, no
visible Fit button, and no keyboard. The hardware Back gesture works but
that's the only escape.

**Reproduce:**
1. Open a pane.
2. Wait a couple of seconds.
3. The terminal view fills the screen — no app bar, no back arrow, no
   visible "Fit to screen width" control.

`TerminalScreen.kt` has `LaunchedEffect(showTopBar) { delay(AUTO_HIDE_DELAY_MS); showTopBar = false }`
and toggles `showTopBar` from `onSingleTapUp`, but in practice the
single tap also fires the (broken) `showKeyboard()` and is sometimes
swallowed by the gesture detector — I never managed to surface the top
bar again on this device.

**Suggested fix:** keep the top bar visible (or visible-on-hover) for at
least the first session, or add a subtle persistent edge-handle that
brings it back. Auto-hide is great for video, less so for a terminal
where Back is hidden too.

---

### Bug 6 — Quick Action pill bar shows ~3 of 5 configured actions; not obvious it scrolls

**Severity:** Low.

5 actions are configured (`Clear`, `Disk Usage`, `System Info`, `Top`,
`Git Status` — visible in `Settings`), but only 3 fit on screen at once
in the terminal pill bar. The bar uses a horizontal `ScrollState` (see
`QuickActionBar.kt`), but there is no chevron, fade, or other scroll
indicator at the right edge, so the remaining two pills are easy to
miss.

**Suggested fix:** add a fade-out gradient at the trailing edge or render
a "more" overflow icon when content overflows.

---

### Bug 7 — "Show" toggle on the Password field is plain text, not a real button

**Severity:** Low (cosmetic / a11y).

`uiautomator dump` reports the "Show" affordance as a `TextView`, not a
clickable Button. It does in fact toggle visibility (functional), but it
isn't reachable to TalkBack as a control — the a11y tree just sees text
labeled "Show".

---

### Bug 8 — `EditText` fields on Login/Settings dialogs have empty `text`/`label` until focused

**Severity:** Low (a11y).

In the login screen, the `Username` and `Password` EditText nodes don't
appear in `mobile_list_elements_on_screen` until I tap into them — the
TextView labels show up, but the EditText is hidden from the a11y tree.
This made automation harder (a real human is mostly unaffected, but
TalkBack users probably can't move focus into the field by label).

Same pattern in the New Session dialog and Rename dialog: the `Session
Name` / `New Name` EditText only appears in the a11y tree once focused.

---

### Bug 9 — Login screen has no logo (web has the termigate green-leaf image)

**Severity:** Cosmetic.

The web `/setup` and `/login` pages display the termigate logo at
`/images/termigate-logo.png`. The Android login screen renders just a
green "termigate" text wordmark instead. Minor brand inconsistency.

---

### Bug 10 — Tapping anywhere on a session row in the list does nothing; only chevron expands

**Severity:** Cosmetic / discoverability.

In `SessionListScreen`, the only ways to interact with a session card
are:
- Pencil icon → menu (Rename / New Window / Kill Session)
- Chevron icon → expand to see panes
- Once expanded, tap a specific pane to open it.

Tapping the session name itself ("main") does nothing. Discoverability
suffers — most users will tap the title first. Consider treating a tap
on the row as "expand", consistent with material list-card conventions.

---

## What works well

For the record, these flows worked end-to-end without surprises:

| Flow | Result |
|------|-------|
| First-run setup via desktop browser | OK — username `drive`, password `drivepass123`, redirect to `/login`. |
| Browser login | OK. |
| Android initial connect (after Bug 1 workaround) | OK — `Login success: drive from 192.168.2.2`, channel join in 89ms. |
| Session list shows real-time tmux state | OK — `main` session listed with `1 window · 1 pane`. |
| Expand session card | OK — chevron toggles, shows `Window 0 / bash / pane 0 · 80x24`. |
| Open a pane → connect | OK — terminal channel joins, Quick Actions pulled (`GET /api/quick-actions`). |
| Quick Action `Disk Usage` | OK — `df -h` runs, output streams back. |
| Create new session via FAB | OK — created `drivetest`, `POST /api/sessions` → 201. |
| `New Window` on a session | OK — `POST /api/sessions/drivetest/windows` → 201. |
| `Split Horizontal` on a pane | OK — `POST /api/panes/drivetest:0.0/split` → 201, list updates to `2 windows · 3 panes`. |
| Rename session | OK — `PUT /api/sessions/drivetest` renames to `renamed`. |
| Kill session (with confirmation dialog) | OK — `DELETE /api/sessions/renamed`, list collapses to just `main`. |
| Settings screen | OK — Quick Actions list, Font Size slider (8–24), Keep Screen On, Vibrate on Special Keys, Connection URL, Logout, About. |
| Hardware Back from terminal | OK — returns to session list. |
| Logout | OK — clears token, returns to login screen. URL and username remembered, password cleared. |

## Environment notes

- Container build: `localhost/termigate:latest` from `Containerfile`,
  Debian trixie-slim base, ~200 MB.
- Container runtime: `podman` 5.8.1, rootless, port `9999:8888`.
- `~/.config/termigate` on the host is **untouched** — drive used
  `/tmp/termigate-drive/config` mounted into the container.
- Real termigate server on the host at port 8888 was left alone.
- AVD: `medium_phone` (`emulator-5554`), Android 16 (SDK 36), x86_64,
  1080×2400, 420 dpi.
- adb 35.0.2 / Java OpenJDK 21 / Android SDK at `~/Android/Sdk`.

## Reset / cleanup

```
podman rm -f termigate-drive
adb -s emulator-5554 reverse --remove-all
adb emu kill        # or leave the emulator running
rm -rf /tmp/termigate-drive
```
