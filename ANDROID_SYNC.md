# ANDROID_SYNC.md — bringing the Android app into sync with the mobile web view

## Goal

The mobile web view recently shifted away from the "client drives tmux pane
size" model. On small screens, the tmux pane now keeps its own dimensions and
the browser scrolls the pane; resizing to fit the viewport is an **explicit**
user action (the repurposed Restore button). The Android app still behaves the
old way — every rotation, keyboard pop, or initial mount pushes the Android
view's measured columns/rows to the server and tmux shrinks to fit. We need to
bring Android in line with the web's mobile experience.

## What changed on the web (reference commits)

| Commit    | Summary                                                              |
|-----------|----------------------------------------------------------------------|
| `2440e10` | Preserve tmux pane dimensions on mobile; skip `fitAddon.fit()`; overflow-auto container with `max-content` child |
| `4fd7151` | Add `overflow-hidden` on the outer multi-pane flex container so pane-level scrolling stays contained |
| `a9398e7` | Repurpose the Restore button on mobile: push `fit_pane_width` (new `RestoreOrFitHook`) that computes cols from viewport-width ÷ measured cell width |
| `b2b33f1` | Relax outer overflow to `overflow-x-hidden` so the soft keyboard doesn't hide the terminal's bottom rows |

Key web behaviors to mirror:

1. **No implicit resize on mobile.** Client never pushes `resize` to the server
   based on its own view geometry (rotation, keyboard, initial mount, etc.).
2. **Pane renders at tmux's native cols/rows.** The surface may be wider or
   taller than the viewport; the app scrolls the pane inside a scroll
   container.
3. **Explicit "Fit to screen width" action.** A button that computes
   `floor(viewport_width / cell_width_px)`, clamps to ≥ 2, and pushes a
   resize to the server.
4. **Vertical page scroll stays available** when the keyboard is up so the
   user can reach the bottom rows of the terminal.

## Current Android behavior (what's wrong)

Files in `android/app/src/main/java/org/tamx/termigate/ui/terminal/`.

- `TerminalScreen.kt` wraps `TerminalView` (from `com.termux.view`) in
  `AndroidView` with `modifier = Modifier.weight(1f)` — the view expands to
  fill the available space. Termux's
  `TerminalView.onSizeChanged → updateSize()`
  (`android/terminal-lib/.../view/TerminalView.java:978,984`) computes
  `newColumns = max(4, viewWidth / mRenderer.mFontWidth)` and
  `newRows = max(4, (viewHeight - …) / mFontLineSpacing)`, then — **if the
  new dims differ from the emulator's current dims** — calls
  `mTermSession.updateSize(newColumns, newRows, cellW, cellH)`, resets
  `mTopRow = 0`, calls `scrollTo(0, 0)`, and invalidates.
- `TerminalScreen.kt:311` — in `onEmulatorSet`, the code calls
  `viewModel.sendResize(emulator.mColumns, emulator.mRows)`. This is the
  Android equivalent of `fitAddon.fit()` + `channel.push("resize", …)` — the
  one thing the web mobile view now avoids. This is the **only** caller of
  `sendResize` outside the new fit action we're about to add.
- `TerminalViewModel.sendResize` debounces 150ms and then calls
  `terminalRepo.sendResize(target, cols, rows)`, which pushes `"resize"` on
  the Phoenix channel. Server handler (`terminal_channel.ex:74`) validates
  bounds and calls `PaneStream.resize`, which runs
  `tmux resize-pane -t <pane_id> -x <cols> -y <rows>`.
- `TerminalViewModel` also keeps a `serverResizeInProgress` flag
  (`TerminalViewModel.kt:55, 168, 190`) to suppress echo loops between
  server-pushed `resized` events and client-pushed resizes. Once client
  resize goes away, this flag is dead weight.
- `TerminalViewModel.connect(cols = 80, rows = 24)` — join payload carries
  these dims, which the server's `maybe_resize_and_recapture` uses to resize
  tmux on join as well. Web mobile is approximately the same (xterm's default
  cols/rows on first construction), so this is acceptable parity.
- `RemoteTerminalSession.updateSize` blindly trusts the view-driven cols/rows
  for the emulator: creates the emulator at view dims on first call, resizes
  it on every subsequent call.
- `TerminalEvent.Resized` is routed to `remoteSession.resizeEmulator(cols, rows)`
  (`TerminalViewModel.kt:191`), so server → client resize already works
  correctly; nothing to change on that path.
- **Pane dims are already exposed** via the REST API: `Pane` in
  `data/model/Session.kt` has `width`/`height`, and `ApiClient.listSessions`
  returns them. The Phoenix channel `join` reply, however, returns only
  `{history: <base64>}` — it does **not** include cols/rows
  (`terminal_channel.ex:43`).
- There is **no** user-visible "Fit to screen" / "Restore" action on the
  Android terminal. The only top-bar affordance is the back arrow.
- Android has no multi-pane grid screen. Navigation (`AppNavigation.kt`,
  4 screens: Login / SessionList / Terminal / Settings) means `TerminalScreen`
  is analogous to the web's *maximized* single-pane view only.

Net effect: the tmux pane is permanently clamped to whatever the phone's
current geometry allows. Rotate → tmux resizes. Open the keyboard → tmux
resizes to the now-shorter view → server echoes a `resized` event back →
emulator shrinks rows → scrollback rewraps. Every one of those moments is a
destructive pane resize on the server.

## Target design on Android

Mirror the web mobile behavior:

1. `TerminalView` renders at tmux's current cols × rows. The view's **pixel**
   size is `(tmuxCols * cellWidthPx, tmuxRows * cellHeightPx)`, not the
   container's size.
2. The `TerminalView` sits inside a scroll container (horizontal + vertical)
   so that when the tmux pane is larger than the viewport the user can pan.
3. Rotation, keyboard, and window-insets changes do **not** send a resize to
   the server. The emulator dimensions track the server (via `resized`
   channel events), not the local view.
4. A "Fit to screen width" icon appears in the auto-hiding top bar. Tapping
   it computes `floor(viewport_width_px / cellWidthPx)`, clamps to ≥ 2, and
   pushes `"resize"` on the existing channel with the same column count
   and the current `rows` (or a row count that fits the visible vertical
   area — see §"Row handling" below).
5. `imePadding()` remains on the outer column so the IME doesn't cover the
   terminal. The scroll container ensures the bottom rows are reachable
   when the keyboard is up.

## Implementation plan

### Phase 1 — Stop client-driven resize

**Files:**
- `android/app/src/main/java/org/tamx/termigate/ui/terminal/TerminalScreen.kt`
- `android/app/src/main/java/org/tamx/termigate/ui/terminal/RemoteTerminalSession.kt`
- `android/app/src/main/java/org/tamx/termigate/ui/terminal/TerminalViewModel.kt`

**Changes:**

1. In `TerminalScreen.kt`'s `TerminalViewClient.onEmulatorSet`, **remove** the
   `viewModel.sendResize(emulator.mColumns, emulator.mRows)` call. This is the
   direct parallel to removing the mobile branch of `fitAddon.fit()` on the
   web.
2. In `RemoteTerminalSession.kt`, change `updateSize` so it does not resize
   the emulator based on the view's pixel size. The emulator's cols/rows
   should only change in response to server `resized` events
   (`TerminalEvent.Resized`) or the explicit fit action (§Phase 3). The view
   still needs to learn the **cell** pixel dimensions from `updateSize`
   calls and expose them (needed for the fit calculation and for Phase 2's
   explicit sizing).
   - Concretely: cache `cellWidthPixels` / `cellHeightPixels` on the
     session object. On the very first `updateSize` (when `mEmulator` is
     null), still call `initializeEmulator` — the view must have an
     emulator before it can render — but use the tmux cols/rows supplied by
     the caller (§Phase 4's join-reply dims), falling back to the
     view-supplied cols/rows only if no tmux dims are known yet. On
     subsequent `updateSize` calls, update just the cached cell pixel
     dimensions; do not resize the emulator.
3. Remove the `serverResizeInProgress` echo-suppression flag in
   `TerminalViewModel` (fields + references around lines 55, 168, 190).
   After step 1 the only `sendResize` caller is the user-initiated fit
   button, which can't produce an echo loop.

**Critical interaction — scroll reset:** `TerminalView.updateSize`
(`terminal-lib/view/TerminalView.java:984`) resets `mTopRow = 0` and calls
`scrollTo(0, 0)` **whenever `newColumns != mEmulator.mColumns` or
`newRows != mEmulator.mRows`**. If we change `RemoteTerminalSession.updateSize`
to keep the emulator at tmux dims while the view dims are driven by the
container, every layout pass will trigger this reset. Phase 2 must size the
`AndroidView` to exactly `mColumns * cellWidthPx × mRows * cellHeightPx` so
that `newColumns == mEmulator.mColumns` and the reset is skipped.

**Test plan:**
- Rotate the device with an active session → tmux pane cols/rows unchanged
  (verify on server via `tmux list-panes -F '#{pane_width}x#{pane_height}'`).
- Open/close the soft keyboard → same.
- Reconnect (toggle wifi) → session resumes; server-side `resized` events
  still drive emulator dims.
- Scroll position is preserved across rotation and keyboard show/hide
  (verifies the scroll-reset interaction is avoided).

### Phase 2 — Render terminal at tmux-native size with scroll

**Files:**
- `android/app/src/main/java/org/tamx/termigate/ui/terminal/TerminalScreen.kt`

**Changes:**

1. Replace the `AndroidView(modifier = Modifier.weight(1f))` wrapper with a
   scroll container:
   ```
   Box(
     modifier = Modifier
       .weight(1f)
       .horizontalScroll(rememberScrollState())
       .verticalScroll(rememberScrollState())
   ) {
     AndroidView(factory = …, modifier = Modifier.size(paneWidthDp, paneHeightDp))
   }
   ```
   where `paneWidthDp` / `paneHeightDp` are derived from the session's cached
   cell pixel dimensions × tmux's current cols/rows (converted via
   `LocalDensity`).
2. Expose a reactive `paneSize: StateFlow<IntSize>` (or pair of `cols`/`rows`
   + `cellWidthPx`/`cellHeightPx`) from `TerminalViewModel`. Update it from:
   - Initial `TerminalConnection` (see §Phase 4 for server-side plumbing of
     initial dims).
   - `TerminalEvent.Resized` handler.
   - First `updateSize` callback from `TerminalView` — we need the cell
     pixel dims before we can size the view. Use a sensible default
     placeholder until the first measure lands.
3. The cell pixel dims may be zero on the very first composition (before the
   view has drawn). Handle this by rendering with
   `fillMaxSize()` during the bootstrap and switching to the
   explicit-size/scrollable layout once `cellWidthPx > 0`. During bootstrap
   the emulator size will match the container (one-time, non-destructive;
   this mirrors the fact that xterm.js is also initially sized by its DOM
   parent before the first mobile render).

**Test plan:**
- Connect to a pane whose tmux cols (e.g. 150) exceed the phone viewport
  (say 60 cell widths). The terminal should render full-width and the pane
  should be horizontally scrollable; letters should not wrap or clip.
- Connect to a pane that fits the viewport. No scrollbar artifacts.
- Rotate device: view pixel dims change, scroll container re-measures, but
  tmux cols/rows remain.

### Phase 3 — Add an explicit "Fit to screen width" action

**Files:**
- `android/app/src/main/java/org/tamx/termigate/ui/terminal/TerminalScreen.kt`
- `android/app/src/main/java/org/tamx/termigate/ui/terminal/TerminalViewModel.kt`

**Changes:**

1. In the auto-hiding `TopAppBar` in `TerminalScreen.kt`, add an `IconButton`
   to the right (actions slot) labelled "Fit to screen width". For the
   icon: `Icons.Filled.FitScreen` lives in `material-icons-extended`; the
   current `app/build.gradle` likely only pulls `material-icons-core` (the
   file uses `Icons.AutoMirrored.Filled.ArrowBack` which is core). Options:
   (a) add the `material-icons-extended` dependency, (b) use a core-only
   fallback like `Icons.Filled.ZoomOutMap`, or (c) ship a small vector
   drawable matching the web's `hero-arrows-pointing-in-micro`. Wire
   `onClick` to a new `viewModel.fitPaneToScreenWidth(viewportWidthPx)`.
2. Implement `TerminalViewModel.fitPaneToScreenWidth(viewportWidthPx: Int)`:
   - Read the session's cached `cellWidthPx` (from Phase 1 changes).
   - `val cols = max(2, viewportWidthPx / cellWidthPx)` — matches the web's
     `Math.max(2, Math.floor(window.innerWidth / cellWidth))`.
   - Keep current `rows` (do not vertically resize — symmetric with the web,
     which only shrinks width). If a "fit rows" action is desired later, add
     it separately.
   - Call `terminalRepo.sendResize(target, cols, rows)`.
3. Capture the viewport width in Compose via `BoxWithConstraints` or
   `LocalDensity` + the screen's content-width reference, and pass it into
   the `onClick` handler. Subtract any horizontal inset padding so the
   computed `cols` accounts for what the user can actually see.
4. Gate the button's enabled state on `cellWidthPx > 0` so it's disabled
   during the bootstrap moment before first measure.

**Test plan:**
- Large tmux pane (e.g. 200 cols), phone portrait → tap Fit → pane shrinks
  to phone-visible cols; verify on server that `tmux list-panes` shows the
  new width.
- Small tmux pane (already narrower than viewport) → Fit is a no-op
  effectively (server clamps, and the existing `@min_cols` on the channel
  will gate silly values).
- Disabled until the view has rendered once.

### Phase 4 — Include cols/rows in the channel join reply (required)

The web's `fit_pane_width` LiveView event is **not** needed on the channel —
Android already has the `"resize"` channel event, and that calls
`PaneStream.resize → tmux resize-pane -x cols -y rows`. So no new server
events are needed for Phase 3.

But the join reply's payload — `terminal_channel.ex:43`:
```elixir
{:ok, %{history: Base.encode64(history)}, socket}
```
only returns `history`. Without cols/rows in the reply, Android has no way
to size the `TerminalView` correctly on initial connect: the server might
have resized tmux via `maybe_resize_and_recapture` (if join params carry
cols/rows), or might have left tmux at its prior dims. Either way, the
emulator first gets created at view-driven dims (because `TerminalView`'s
own `onSizeChanged → updateSize` runs before any `resized` event arrives),
and there's no `resized` event on join to correct it.

**Server change:**

Update `terminal_channel.ex:24` (join handler) to read the post-resize
dimensions from `PaneStream` state and include them in the reply:
```elixir
{cols, rows} = PaneStream.dimensions(target)  # new helper, or read from state
{:ok, %{history: Base.encode64(history), cols: cols, rows: rows}, socket}
```
`PaneStream` already tracks these (it runs `tmux resize-pane` and the
server pushes `{:pane_resized, cols, rows}` messages elsewhere). Expose a
sync accessor if not already present.

**Alternative (no server change):** Call `ApiClient.listSessions` before
connect, find the matching `Pane` by `target`, read `width`/`height` — the
`Pane` model already carries them
(`data/model/Session.kt:22-23`). This avoids any server touch but costs an
extra HTTP round-trip per connect. Prefer the channel-reply approach.

**Android change (either approach):** parse `cols`/`rows` from the join
reply in `TerminalRepository.connect` and include them in
`TerminalConnection`. Pass them through `TerminalViewModel.connect` so the
first call to `RemoteTerminalSession.initializeEmulator` (via the overridden
`updateSize`) uses the tmux dims, not the view dims. Requires a small
re-ordering: the session needs to know the target dims *before*
`attachSession` triggers the first `updateSize`.

### Phase 5 — Polish & parity

1. Update the top-bar tooltip / content description to match the web tooltip
   wording: "Fit to screen width". The web uses "Restore (mobile: fit to
   screen width)" on a dual-purpose button, but Android's terminal screen
   has no "restore to grid" analog (no multi-pane view on Android today), so
   just call it "Fit to screen width".
2. Confirm `imePadding()` on the terminal `Column` still reaches the bottom
   of the scroll container — verify by focusing an editor at the tmux
   pane's bottom row with the keyboard open.
3. Match the color / alpha of the top-bar surface to the web header (the
   web recently collapsed window tabs / control bar behind a header toggle;
   Android's auto-hide is a reasonable analog — no action item unless the
   user wants explicit toggle parity).
4. Ensure the existing `SpecialKeyToolbar` and `QuickActionBar` don't force
   the terminal container to shrink — they're already laid out above/below
   the weighted terminal box and should be fine.

## Edge cases & open questions

- **Keyboard + scroll interaction.** Verify that the vertical scroll inside
  the terminal container takes precedence over page-level scroll when the
  keyboard is open. Compose's `verticalScroll` + `imePadding` should Just
  Work; sanity-check manually.
- **Gesture conflict.** Termux `TerminalView` does its own pan/pinch. If
  horizontal scroll of the outer container clashes with TerminalView's own
  touch handling (e.g. selection), we may need to either:
  - Disable TerminalView's horizontal gestures (already narrow: it's mainly
    text selection), or
  - Keep horizontal scroll on the outer container and accept that the
    user's first horizontal drag scrolls the pane into view (most common
    case) — matches web's trackpad scroll behavior.
- **Rows.** We currently send `rows = emulator.mRows` on fit. Consider
  whether fit should also shrink rows to the visible height. Web does not
  (it only adjusts width); keep parity unless the product decision changes.
- **Tablets in landscape.** The web's mobile branch triggers at `< 640px`.
  Android does not have a direct analog; the app behaves "mobile" always.
  That matches the pragmatic reality for the current Android UX (single
  terminal screen, no multi-pane grid). Revisit if a tablet layout lands.
- **Screenshot reference:** `Screenshot_From_2026-04-14_18-27-35.png` in
  the repo root was taken just before commit `a9398e7`; it captures the
  mobile multi-pane overflow moment the fit-button change was designed to
  address.

## Files to touch (summary)

| File                                                             | Change                                                                  |
|------------------------------------------------------------------|-------------------------------------------------------------------------|
| `android/.../ui/terminal/TerminalScreen.kt`                      | Remove `onEmulatorSet` resize; wrap terminal in scroll + explicit size; add Fit button to top bar |
| `android/.../ui/terminal/TerminalViewModel.kt`                   | Add `fitPaneToScreenWidth(viewportWidthPx)`; expose cols/rows/cellPx state; drop `serverResizeInProgress` |
| `android/.../ui/terminal/RemoteTerminalSession.kt`               | Override `updateSize` to cache cell pixel dims without mutating emulator cols/rows |
| `android/.../data/repository/TerminalRepository.kt`              | Parse `cols`/`rows` from join reply; add to `TerminalConnection`        |
| `server/lib/termigate_web/channels/terminal_channel.ex`          | Include `cols`/`rows` in the join reply (required for correct initial sizing) |

## Out of scope

- Multi-pane grid on Android (web has one, Android does not; adding a grid
  is a larger feature, not a sync task).
- Re-theming to match the web's collapsible header toggle.
- Changes to `QuickActionBar` / `SpecialKeyToolbar` layout.
