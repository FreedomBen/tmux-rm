# Phase 12: Multi-Pane Split View

## Goal
Implement `MultiPaneLive` — a view that shows all panes in a tmux window side-by-side, mirroring tmux's split-pane layout. Includes window tabs for navigation between windows in a session. After this phase, users can view an entire tmux window's layout in the browser.

## Dependencies
- Phase 5 complete (TerminalLive / TerminalHook)
- Phase 4 complete (session list with navigation)

## Steps

### 12.1 MultiPaneLive

**`lib/remote_code_agents_web/live/multi_pane_live.ex`**:

**Routes**:
- `/sessions/:session` — redirects to the session's active window (via `tmux display-message -p -t {session} '#{window_index}'`)
- `/sessions/:session/windows/:window` — shows all panes in the specified window

**`mount/3`**:
1. Parse session and window from params
2. Subscribe to PubSub topics: `"sessions"` (window add/remove), `"layout:{session}:{window}"` (layout changes)
3. Fetch window list for the session (for tab bar)
4. Fetch initial layout from `LayoutPoller.get(session, window)` (starts poller if not running)
5. For each pane, call `PaneStream.subscribe/1` — get history and PID
6. Monitor all PaneStream PIDs

**`handle_info` callbacks**:
- `{:layout_updated, panes}` — compare to current pane set. Subscribe to new panes, unsubscribe from removed panes, update CSS Grid layout.
- `{:sessions_updated, _}` — update window tab list
- `{:pane_output, target, data}` — route to correct xterm.js instance using `target` to identify the pane
- `{:pane_dead, target}` — mark pane as dead in layout
- `{:pane_resized, cols, rows}` — update pane dimensions in layout
- `{:DOWN, ...}` — PaneStream crashed, re-subscribe

**`terminate/2`**:
- Unsubscribe from all PaneStreams (each one independently enters its grace period)

**PaneStream lifecycle in multi-pane**: All PaneStreams for a window are subscribed at mount time. When the user navigates away, `terminate/2` unsubscribes from all of them simultaneously. Each PaneStream independently enters its grace period and shuts down if no other viewers remain. If the user navigates to a different window in the same session, new PaneStreams are subscribed for the new window's panes while the old ones enter grace period.

### 12.2 Window Tabs

Tab bar across the top of the multi-pane view:
- One tab per window in the session
- Show window index and name (if set)
- Click tab → navigate to that window's URL
- Highlight active window tab
- Tabs update from SessionPoller broadcasts — window add/remove/rename detected automatically

### 12.3 CSS Grid Layout

Map tmux's pane coordinates to CSS Grid using proportional sizing:

**Algorithm**:
1. Query pane geometry: `tmux list-panes -t {session}:{window} -F '#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}'`
2. Compute total window dimensions: `total_width = max(pane.left + pane.width)`, `total_height = max(pane.top + pane.height)` across all panes (add 1 for each separator)
3. Collect unique column boundaries (sorted `pane.left` values + right edges) and row boundaries (sorted `pane.top` values + bottom edges) — these become the grid tracks
4. Convert each track to a proportional `fr` value: `track_size / total_size` (use `fr` units, not percentages, for better distribution)
5. Place each pane by finding its start/end column and row indices in the boundary arrays

```elixir
# Example: two panes side-by-side (60 cols | 60 cols)
# pane %0: left=0, top=0, width=60, height=40
# pane %1: left=61, top=0, width=60, height=40
# → grid-template-columns: 60fr 60fr
# → grid-template-rows: 40fr
# → pane %0: grid-column: 1/2; grid-row: 1/2
# → pane %1: grid-column: 2/3; grid-row: 1/2
```

**Note on fidelity**: CSS Grid uses proportional sizing which closely approximates tmux's character-cell layout but may differ by a few pixels. This is acceptable — the web view is a monitor, not a pixel-perfect replica. Each pane's xterm.js instance will `fit()` to its grid cell and may have slightly different dimensions than the tmux pane.

Template approach:
```heex
<div
  id="multi-pane-grid"
  style={"display: grid; grid-template-columns: #{grid_cols}; grid-template-rows: #{grid_rows}; gap: 2px;"}
  class="h-full"
>
  <div
    :for={pane <- @panes}
    style={"grid-column: #{pane.grid_col}; grid-row: #{pane.grid_row};"}
    id={"pane-#{pane.target}"}
    phx-hook="TerminalHook"
    phx-update="ignore"
    data-target={pane.target}
    class="border border-gray-700 min-h-0 overflow-hidden"
  >
  </div>
</div>
```

### 12.4 Multiple TerminalHook Instances

The TerminalHook needs to support multiple instances on the same page:
- Each hook instance creates its own xterm.js Terminal
- Each receives output for its specific pane (via `data-target` attribute)
- Server-side: push events are scoped by pane target
- Focus management: clicking a pane focuses it, sends input to that pane

Update `terminal_hook.js`:
- Use `this.el.dataset.target` to identify which pane this hook manages
- Scope event listeners to the specific pane
- Support multiple hook instances on one page

### 12.5 Resize Behavior

In multi-pane view, all panes are **passive resizers**:
- Read current pane dimensions on connect
- Render at that size (may scale to fit grid cell)
- Do NOT send resize events on browser resize
- tmux controls the layout — web view mirrors it
- Users who want to resize should use tmux commands or the single-pane full-viewport view

### 12.6 Single-Pane Navigation

- Clicking a pane in the session list still opens the single-pane full-viewport view (existing `TerminalLive`)
- Multi-pane view has a "Focus" button per pane that opens `TerminalLive` for that pane
- Back navigation from TerminalLive returns to MultiPaneLive

### 12.7 Mobile Behavior

Multi-pane view is desktop/tablet only (>640px):
- **Mobile (<640px)**: Show window tabs at top + list of panes for the selected window. Tap a pane → open full-viewport TerminalLive.
- No CSS Grid layout on mobile — panes listed vertically as cards with preview thumbnails (or just metadata)
- Alternatively: horizontal swipe between panes in the same window

### 12.8 LayoutPoller GenServer

**`lib/remote_code_agents/layout_poller.ex`**:

Shared layout poller that avoids redundant `tmux list-panes` calls across multiple viewers of the same window. Same pattern as `SessionPoller`.

- **Key**: `{session, window}` — one LayoutPoller per active window
- **Started lazily**: `LayoutPoller.get(session, window)` starts a poller via DynamicSupervisor if not already running
- **Registration**: `{:via, Registry, {PaneRegistry, {:layout_poller, session, window}}}`
- **Polling**: runs `tmux list-panes -t {session}:{window} -F '#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}'` every 2s (tab-separated for reliable parsing)
- **Diffing**: compares new layout to previous; on change, broadcasts `{:layout_updated, panes}` on PubSub topic `"layout:{session}:{window}"`
- **Also subscribes** to PubSub `"sessions"` to trigger immediate re-poll on `{:sessions_changed}` (split/close via app)
- **Grace period**: shuts down 30s after the last viewer unsubscribes from its PubSub topic (detected via Phoenix.PubSub listener count, or explicit reference counting)
- **Pane death**: if `list-panes` returns empty or errors (window killed), broadcast final empty layout and terminate

### 12.9 Layout Refresh

The LayoutPoller (every 2-3s) detects layout changes:
- User splits a pane via tmux → new pane appears in grid
- User closes a pane via tmux → pane removed from grid
- User resizes a pane via tmux → grid proportions update
- Smooth transitions via CSS Grid animations
- All viewers of the same window share one poller — no redundant tmux calls

### 12.10 Tests

- Mount multi-pane view with a window containing 2+ panes
- Verify all panes render with xterm.js instances
- Test window tab navigation
- Test pane addition (split via tmux → new pane appears)
- Test pane removal (kill via tmux → pane removed)
- Test mobile fallback (list view instead of grid)
- Test redirect from `/sessions/:session` to active window
- Test LayoutPoller: shared across viewers, grace period shutdown, layout diffing

## Files Created/Modified
```
lib/remote_code_agents/layout_poller.ex
lib/remote_code_agents_web/live/multi_pane_live.ex
lib/remote_code_agents_web/live/multi_pane_live.html.heex
assets/js/hooks/terminal_hook.js (update — multi-instance support)
lib/remote_code_agents_web/router.ex (add routes)
test/remote_code_agents/layout_poller_test.exs
test/remote_code_agents_web/live/multi_pane_live_test.exs
```

## Exit Criteria
- `/sessions/:session/windows/:window` shows all panes in a CSS Grid layout matching tmux
- Window tabs navigate between windows in the session
- Each pane has its own xterm.js instance with streaming output and input
- Focus management: clicking a pane makes it the active input target
- Layout updates within 2-3s when panes are split/closed/resized in tmux
- "Focus" button per pane opens single-pane full-viewport view
- Mobile: list view with tap-to-open instead of grid
- `/sessions/:session` redirects to the active window
