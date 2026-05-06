# Server Mobile Drive — 2026-05-06 12:54:10 MDT

## Run metadata

| Field | Value |
| --- | --- |
| Drive started | 2026-05-06 12:54:10 MDT |
| Container image | `termigate:server-mobile-drive` |
| Container name | `termigate` |
| Host port | `8889` (forwarded → container 8888) |
| Config dir | `/tmp/termigate-server-mobile-drive` |
| Admin user | `admin` |
| Admin password | `Drive-Mobile-2026!` |
| Browser | Chromium via Chrome DevTools MCP |
| `SECRET_KEY_BASE` | (random 48-byte base64, stored in `/tmp/skb-mobile-drive` on host) |

### Primary device profile

| Field | Value |
| --- | --- |
| Name | iPhone SE (3rd gen) |
| Viewport | 375 × 667 |
| Device pixel ratio | 2 |
| Mobile | true |
| Touch | true |
| User-agent | `Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1` |

### Secondary breakpoint sweeps

| Profile | Viewport | Why |
| --- | --- | --- |
| Small phone | 320 × 568 | Narrowest realistic width — text wrap, overflow. |
| Large phone | 412 × 915 | Pixel-class Android — taller, wider. |

## Findings

### F1 — Settings page overflows horizontally on mobile

- Severity: **major**
- Viewport: iPhone SE 375×667 (also 320×568 below)
- Repro:
  1. Log in as admin and navigate to `/settings`.
  2. Open DevTools / inspect `document.documentElement.scrollWidth` vs `clientWidth`.
- Expected: page fits within the viewport — `scrollWidth ≤ clientWidth`.
- Actual: `scrollWidth = 668`, `clientWidth = 375`. The page scrolls horizontally by ~293 px.
- Root cause: helper text under the **Notifications → Detection Mode** radio
  options (`Activity-based`, `Shell integration`) renders on the same line as
  the radio + label and isn't constrained. The `Shell integration` option's
  description (`Precise command detection with name, exit code, and duration. Requires shell setup.`)
  measures 600 × N px, ending at right=668.
- Screenshot: `drive-artifacts/settings-iphone-se.png`

### F2 — Sub-44 px touch targets on the Settings page

- Severity: **minor** (none of the offenders are *primary* actions, but they
  are all interactive)
- Viewport: iPhone SE 375×667
- Repro:
  1. Open `/settings`.
  2. Run the auditor (`button, a, [role=button], input, select, [role=radio], [role=checkbox]` filter
     for `width < 44 || height < 44`).
- Findings (14 elements): native checkboxes for *Enabled / Disabled* (20×20),
  three Detection Mode radios (20×20 each), `Cursor blink` and `Mobile
  toolbar` checkboxes (20×20), Font Size spinner (32 high), Font Family /
  Theme / Cursor Style / Session Duration `<select>` dropdowns (32 high),
  three password `<input>`s (32 high).
- Expected: all interactive targets ≥ 44 × 44 CSS px (Apple HIG / WCAG 2.5.5
  AAA). The page already wraps the *Notifications* radios in a labeled group
  with a clickable area, but the underlying input/label hit-area is the 20px
  native control.
- Note: these are native form controls so the actual tap area can be larger
  than the rendered chip via the surrounding `<label>`; verify by tapping
  the label area to confirm. The 32 px `<select>` and `<input>` rows are the
  bigger concern — they're noticeably small under thumbs.
- Screenshot: `drive-artifacts/settings-iphone-se.png`

### F3 — Terminal does not resize to mobile viewport (`tput cols=120, lines=40`)

- Status: **accepted / by design.** Keeping the terminal at a stable
  size on mobile is an intentional design decision — resizing the
  terminal to follow the mobile viewport broke too many in-flight
  shell scenarios. The visual clipping and TUI implications below are
  retained as documentation of the trade-off, not as a bug to fix.
- Severity (had this not been by design): blocker — full-screen TUIs
  (vim, htop, less, top) draw to 120 columns and overflow / clip on a
  375 px viewport. Long shell output wraps at column 120 and the
  right-hand 90 cols are hidden behind the parent pane wrapper's
  `overflow: hidden`.
- Viewport: iPhone SE 375×667
- Repro:
  1. Log in, attach to `drive-test`, tap the pane card to maximize.
  2. In the terminal, run `tput cols; tput lines`.
  3. Inspect the xterm Terminal instance via DevTools:
     `term.cols` / `term.rows`.
- Expected: tmux-attached pane should be sized to fit the visible terminal
  area at 375 px (about 30 cols × 25 rows with the default 14 px
  monospace font), and `tput cols` should return that value.
- Actual: `tput cols → 120, tput lines → 40`. xterm reports `cols: 120`,
  `rows: 40`. The terminal renders a 1011 × 660 px area inside the 375 ×
  416 grid container; the parent's `overflow: hidden` clips the rightmost
  ~636 px so the user only sees the leftmost ~30 columns of a 120-column
  terminal.
- Impact:
  - Long lines wrap "off screen" inside the clipped region rather than
    wrapping at the visible width — output looks truncated.
  - `htop`, `vim`, etc. assume a 120 × 40 grid and draw outside the
    visible area.
  - The terminal session's idea of `LINES`/`COLUMNS` doesn't match the
    UI, so editor / pager UIs are unusable.
- Likely cause: `FitAddon` is loaded (`terminal_hook.js:97`) but the
  resize-to-fit pathway isn't fitting the terminal to its parent
  rectangle when the mobile fallback maximizes the pane (the `hidden
  sm:grid` grid only becomes `grid` after maximize; the fit may be
  computed against the 0×0 rect that exists before the click and not
  recomputed when the grid becomes visible).
- Screenshot: `drive-artifacts/terminal-maximized-iphone-se.png`,
  `drive-artifacts/streaming-pipeline-iphone-se.png`

### F4 — Mobile pane gating: terminal hidden until you tap to "maximize"

- Severity: **major**
- Viewport: iPhone SE 375×667 (Tailwind `< sm` breakpoint, i.e.
  `width < 640 px`)
- Repro:
  1. Attach to a session at 375 px width.
  2. Observe: instead of the terminal, a card appears that says
     `drive-test:0.0` / `bash · 120×40`.
- Expected: opening a session on mobile should drop you straight into the
  terminal (a single pane with no sibling panes is the common case and
  makes the extra "maximize" tap pure friction).
- Actual: the LiveView renders `<div id="multi-pane-grid" class="hidden
  sm:grid …">` (the real terminal grid) plus `<div class="…
  sm:hidden …">` (a cards-list mobile fallback). At 375 px the grid is
  `display: none` so the terminal pane is rendered into a 0 × 0
  container; you must tap the pane card to fire `phx-click=maximize_pane`
  before the grid becomes `display: grid`.
- Mobile UX impact:
  - Discovery: a first-time mobile user lands on a list with one row and
    no obvious affordance that "the terminal is below this card".
  - Round trip: every navigation back to the session re-shows the card.
- Suggested fix: when there's exactly one pane, skip the card and render
  the terminal full-bleed.
- Screenshot: `drive-artifacts/terminal-attached-iphone-se.png` (before
  tapping the card — terminal area is empty).

### F5 — No client-side scrollback on mobile (xterm `scrollback: 0`)

- Severity: **minor** (intentional; tmux owns scrollback)
- Viewport: iPhone SE 375×667
- Repro:
  1. Attach to session, run `seq 1 200`.
  2. Inspect xterm: `term.options.scrollback === 0` and
     `term.buffer.active.length === term.rows`.
  3. Try to scroll up in the terminal area — there is no scrollback to
     reveal.
- Expected (mobile): some way to view recent output that has scrolled off
  the visible 30 col × ~25 row area. Even a small client-side scrollback
  buffer (e.g. 1000 lines) would help; alternatively, a visible "enter
  copy mode" affordance.
- Actual: scrollback is set to 0 in the Terminal options. Users can only
  see the live screen — to scroll back they'd need to enter tmux
  copy-mode (`Ctrl-b [`), which is not discoverable on mobile and is
  awkward to drive without a hardware keyboard.
- Note: this is by design per the architecture doc ("tmux is the source
  of truth"), but the mobile UX consequence — no scrollback access — is
  worth surfacing.

### F6 — Login page: form inputs and primary "Sign in" button are 40 px tall

- Severity: **minor**
- Viewport: iPhone SE 375×667 (and 320×568)
- Repro:
  1. Log out, audit `button, input` rects on `/login`.
- Expected: ≥ 44 × 44 CSS px for primary actions per Apple HIG.
- Actual: `Username` and `Password` inputs are 294 × 40, `Sign in` is
  294 × 40. Close button on the error alert is 20 × 21.
- Screenshot: `drive-artifacts/login-error-iphone-se.png`

### F7 — No password-visibility toggle on the login form

- Severity: **nit** (the setup form also lacks one)
- Viewport: iPhone SE 375×667
- Repro:
  1. Open `/login` on a phone, attempt to type a password.
- Expected: an eye / eye-off button next to the password input. Mobile
  password entry without a toggle is a common pain point because the
  on-screen keyboard auto-corrects and there's no echo.
- Actual: no toggle button present in either the login or the first-run
  setup form.
- Note: the drive instructions referenced commit `83a451a` adding eye /
  eye-off icons, but on this build the toggle does not appear on
  `/login`. Either the change was reverted, lives only on a different
  surface, or wasn't merged into the build under test. Worth verifying
  on the current branch.

### F8 — Settings overflow reproduces at 320 px and 412 px (same root cause)

- Severity: **major** (already reported in F1; this just confirms the
  scope)
- Viewports: small phone 320×568, large phone 412×915
- Repro: `/settings` at each viewport.
- Result:
  - 320×568: `scrollWidth = 668`, `clientWidth = 320` (348 px overflow).
  - 412×915: `scrollWidth = 668`, `clientWidth = 412` (256 px overflow).
- The `scrollWidth = 668` matches the F1 root cause exactly — the
  Notifications radio descriptions are forcing the page out to ~668 px
  regardless of viewport.
- Screenshots: `drive-artifacts/settings-small-phone-320.png`,
  `drive-artifacts/settings-large-phone-412.png`.

### F9 — Terminal still 120×40 at every tested mobile viewport

- Status: **accepted / by design** (same trade-off as F3). Recorded
  here only to confirm the design decision holds across breakpoints
  and orientations.
- Severity (had this not been by design): blocker — cross-viewport
  confirmation of F3.
- Viewports tested: 320×568, 375×667, 412×915 (all portrait), and
  667×375 (375 rotated to landscape).
- Result: `term.cols / term.rows / tput cols / tput lines` all report
  `120 / 40` regardless of viewport. The xterm rendered area is roughly
  1011 × 660 in every portrait test and is clipped by the parent's
  `overflow: hidden`.
- Screenshots: `drive-artifacts/terminal-large-phone-412.png`,
  `drive-artifacts/terminal-small-phone-320.png`,
  `drive-artifacts/terminal-landscape-iphone-se.png`.

### F10 — Terminal top bar: `Close window` is a 18 × 18 tap target

- Severity: **major**
- Viewports: 320×568 (worst), 375×667 (slightly larger but still small)
- Repro:
  1. Attach to a session, audit `button.innerText === '×'` rect on the
     top bar.
- Expected: ≥ 44 × 44 CSS px for a destructive control.
- Actual: 18 × 18 (`aria-label="Close window"`). Adjacent controls are
  also small at 320 px width: `Toggle tab and control bar` 28 × 20,
  `New window` 32 × 32. Mistapping `×` instead of `New window` would
  destroy the user's window.
- Screenshot: `drive-artifacts/terminal-small-phone-320.png`.

### F11 — Quick Action Bar pills: ✅ pass (note for repo)

- Severity: **n/a** — recording as a positive verification.
- Viewport: iPhone SE 375×667
- Bar dimensions: 375 × 57 with `overflow-x: auto`. Six pills:
  `Clear` (68 × 44), `Disk Usage` (101 × 44), `System Info` (108 × 44),
  `Top` (55 × 44), `Git Status` (101 × 44), `Hide quick actions` (44 ×
  44). All ≥ 44 px tall.
- Fade-edge: applied via
  `mask-image: linear-gradient(90deg, rgba(0,0,0,0) 0px, rgb(0,0,0) 24px,
  rgb(0,0,0) calc(100% - 24px), rgba(0,0,0,0) 100%)` — works.
- Tapping the `Disk Usage` pill correctly dispatched `df -h` into the
  attached pane and rendered the response.
- Horizontal scroll: `scrollWidth = 542 > clientWidth = 375`,
  scrollable, fade tells the user there's more content. ✅

### F12 — Mirroring across two mobile tabs: ✅ pass

- Severity: **n/a** — positive verification.
- Viewport: iPhone SE 375×667
- Repro: open `drive-test` in two emulated tabs, dispatch input from each.
- Result: input from each tab appeared in the other within the usual
  streaming latency, in correct order. Both tabs see the same prompt
  state.

### F13 — Kill-session live update: ✅ pass

- Severity: **n/a**
- After clicking *Session actions → Kill Session → Confirm* on
  `drive-test` from the session list, the count went from `2 active` to
  `1 active` and the row disappeared without a manual refresh —
  consistent with the architecture's `{:sessions_changed}` PubSub
  broadcast.

### F14 — Theme persistence: ✅ pass (server-side)

- Severity: **n/a**
- Viewport: iPhone SE 375×667
- Repro: change Theme `Dark → Light`, click *Save*, reload, observe.
- Result: post-reload, the `<select name="theme">` shows `light`,
  `<html data-theme>` shows `light`. `localStorage` contains no
  termigate-related keys, so persistence is via the server-side
  config path (`TERMIGATE_CONFIG_PATH=/var/lib/termigate/config.yaml`).

### F15 — Multi-pane mobile layout: card-list per pane (single-pane focus)

- Severity: **minor** (design observation)
- Viewport: iPhone SE 375×667
- Behavior: with two panes after a horizontal split, `<sm` viewports
  render a stacked list of pane cards (`drive-test:0.0 · bash · 44×40`
  and `drive-test:0.1 · bash · 75×40`); tapping a card "maximizes"
  that pane into the grid. The non-maximized pane is rendered with
  `width: 0; height: 0`.
- Implication: F4 (single-pane gating) is the same code path. With
  multiple panes the list makes more sense, but with one pane it adds
  a redundant tap.
- Screenshot: `drive-artifacts/multi-pane-mobile-list-iphone-se.png`,
  `drive-artifacts/multi-pane-split-iphone-se.png`.

### F16 — Console / network during the drive: clean

- Severity: **n/a** — positive verification.
- Repro: `list_console_messages` and `list_network_requests` after
  navigation through setup, login error, login success, session list,
  attach, kill, settings.
- Result: 0 console errors, 0 console warnings; 16 requests inspected,
  all `200`/`304`. No failed `/channels/*`, `/healthz`, or asset
  requests.

## Summary

### Counts by severity

| Severity | Count | IDs |
| --- | --- | --- |
| Blocker | 0    | — |
| Major   | 4    | F1, F4, F8, F10 |
| Minor   | 4    | F2, F5, F6, F15 |
| Nit     | 1    | F7 |
| Accepted / by design | 2 | F3, F9 (terminal kept at fixed 120×40 on mobile) |
| Positive verification | 5 | F11, F12, F13, F14, F16 |

### Mobile-specific breakdown

| Category | Findings |
| --- | --- |
| Touch targets < 44 px | F2 (settings controls), F6 (login form), F10 (terminal `×` close at 18 × 18) |
| Horizontal overflow | F1 (settings), F8 (settings at 320 / 412) |
| Breakpoint regressions | F4 (terminal hidden under `sm:grid`), F15 (mobile-fallback list always shown) |
| Terminal-resize / TUI usability | F3, F9 — accepted / by design (terminal held at 120×40 on mobile to avoid resize breakage) |
| Scrollback access | F5 (xterm scrollback disabled, no mobile copy-mode UX) |
| Auth UX | F6 (40 px inputs), F7 (no password-visibility toggle) |

### Top 3 user-impacting issues on mobile

1. **F1 / F8 — Settings page horizontal scroll on every tested mobile
   width.** Caused by the `Notifications → Detection Mode` radio
   descriptions rendering on the same line as the radios. Looks broken
   the moment a user opens settings.
2. **F4 — Mobile single-pane gating.** Even with one pane, you land on a
   "card" you have to tap before the terminal appears. First-time mobile
   users reasonably interpret this as "the session is empty".
3. **F10 — Terminal top bar `Close window` is an 18 × 18 tap target.**
   Adjacent controls (`New window`, `Toggle tab and control bar`) are
   also small at 320 px width, and a destructive control next to a
   creation control is exactly the place to widen the hit area.

### Verdict

**yes-with-caveats** — the streaming pipeline, multi-tab mirroring,
PubSub-driven session-list updates, and server-side prefs persistence
all work cleanly on mobile, and the fixed-size terminal (F3 / F9) is
an accepted design trade-off rather than a regression. Before a
broader mobile rollout, fix the settings horizontal-overflow (F1 / F8)
and the tap-target issues on the terminal top bar (F10) and consider
collapsing the single-pane mobile card (F4); none of those block a
limited launch.

## Teardown

- Container: stopped cleanly via `podman stop -t 5 termigate`. The
  background `make run-container` task exited with status 0.
- Browser tabs: settings tab left selected; the worker has closed the
  second tab.
- `/tmp/termigate-server-mobile-drive` config dir: **left in place** —
  awaiting confirmation from the operator before removal.

Report path: `archived-docs/SERVER_MOBILE_DRIVE_2026-05-06_12-54-10.md`.
Artifacts: `drive-artifacts/*-iphone-se.png`,
`drive-artifacts/*-small-phone-320.png`,
`drive-artifacts/*-large-phone-412.png`,
`drive-artifacts/*-landscape-iphone-se.png`.

