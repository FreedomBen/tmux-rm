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
2. Subscribe to PubSub topic `"sessions"` (for window add/remove/rename detection)
3. Fetch window list for the session (for tab bar)
4. Poll pane layout: `tmux list-panes -t {session}:{window} -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'`
5. For each pane, call `PaneStream.subscribe/1` — get history and PID
6. Monitor all PaneStream PIDs
7. Start layout poll timer (`Process.send_after(self(), :poll_layout, 2_000)`)

**`handle_info` callbacks**:
- `:poll_layout` — re-fetch pane layout from tmux, compare to current. If changed, update CSS Grid layout, re-subscribe to new panes, unsubscribe from removed panes. Reschedule poll.
- `{:sessions_updated, _}` — update window tab list
- `{:pane_output, target, data}` — route to correct xterm.js instance using `target` to identify the pane
- `{:pane_dead, target}` — mark pane as dead in layout
- `{:pane_resized, cols, rows}` — update pane dimensions in layout
- `{:DOWN, ...}` — PaneStream crashed, re-subscribe

**`terminate/2`**:
- Unsubscribe from all PaneStreams

### 12.2 Window Tabs

Tab bar across the top of the multi-pane view:
- One tab per window in the session
- Show window index and name (if set)
- Click tab → navigate to that window's URL
- Highlight active window tab
- Tabs update from SessionPoller broadcasts — window add/remove/rename detected automatically

### 12.3 CSS Grid Layout

Map tmux's pane coordinates to CSS Grid:

```javascript
// Given panes with {left, top, width, height} from tmux:
// Build a CSS Grid where each pane maps to a grid area

function buildGridLayout(panes) {
  // tmux coordinates are in character cells
  // Map to CSS Grid template columns/rows
  // Each pane becomes a grid item placed at its coordinates
}
```

Template approach:
```heex
<div
  id="multi-pane-grid"
  style={"display: grid; grid-template-columns: #{grid_cols}; grid-template-rows: #{grid_rows};"}
  class="h-full"
>
  <div
    :for={pane <- @panes}
    style={"grid-column: #{pane.grid_col}; grid-row: #{pane.grid_row};"}
    id={"pane-#{pane.target}"}
    phx-hook="TerminalHook"
    phx-update="ignore"
    data-target={pane.target}
    class="border border-gray-700 min-h-0"
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

### 12.8 Layout Refresh

The `list-panes` poll (every 2-3s) detects layout changes:
- User splits a pane via tmux → new pane appears in grid
- User closes a pane via tmux → pane removed from grid
- User resizes a pane via tmux → grid proportions update
- Smooth transitions via CSS Grid animations

### 12.9 Tests

- Mount multi-pane view with a window containing 2+ panes
- Verify all panes render with xterm.js instances
- Test window tab navigation
- Test pane addition (split via tmux → new pane appears)
- Test pane removal (kill via tmux → pane removed)
- Test mobile fallback (list view instead of grid)
- Test redirect from `/sessions/:session` to active window

## Files Created/Modified
```
lib/remote_code_agents_web/live/multi_pane_live.ex
lib/remote_code_agents_web/live/multi_pane_live.html.heex
assets/js/hooks/terminal_hook.js (update — multi-instance support)
lib/remote_code_agents_web/router.ex (add routes)
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
