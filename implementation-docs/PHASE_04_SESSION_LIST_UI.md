# Phase 4: Session List Web UI

## Goal
Implement the `SessionListLive` page and the `SessionPoller` GenServer. After this phase, users can browse tmux sessions in the web UI, create new sessions, and navigate to terminal views.

## Dependencies
- Phase 2 complete (TmuxManager)
- Phase 1 complete (layout, Tailwind Plus components)

## Steps

### 4.1 SessionPoller GenServer

**`lib/remote_code_agents/session_poller.ex`**:

- Polls `TmuxManager.list_sessions/0` (with panes via `list_panes/1`) every `session_poll_interval` (default 3s)
- Compares result to previous snapshot; if changed, broadcasts `{:sessions_updated, sessions}` on PubSub topic `"sessions:state"`
- Exposes `SessionPoller.get/0` — `GenServer.call` returning the last-known session list (synchronous read, no file I/O). Returns `[]` before the first poll completes.
- Performs the first poll asynchronously via `handle_continue(:initial_poll, state)` to avoid blocking the supervision tree if tmux is slow or unavailable. `get/0` returns `[]` before the first poll completes, which is acceptable (the UI shows an empty state briefly, then updates via PubSub within milliseconds).
- Also subscribes to PubSub topic `"sessions:mutations"` to handle `{:sessions_changed}` from `TmuxManager` mutations (immediate re-poll on app-driven changes)

**PubSub topic separation**: `"sessions:mutations"` carries `{:sessions_changed}` from TmuxManager (trigger events with no payload). `"sessions:state"` carries `{:sessions_updated, sessions}` from SessionPoller (state snapshots with full session list). LiveViews subscribe to `"sessions:state"` only. SessionPoller subscribes to `"sessions:mutations"` to trigger immediate re-polls.
- Stores the last session list in GenServer state for diffing
- Comparison uses sorted session data (name, window count, pane list) for order-independent equality

### 4.2 SessionListLive

**`lib/remote_code_agents_web/live/session_list_live.ex`**:

**`mount/3`**:
- Subscribe to PubSub topic `"sessions:state"` (receives `{:sessions_updated, sessions}`)
- Fetch initial session list from `SessionPoller.get/0`
- Assign `:sessions` to socket

**`handle_info`**:
- `{:sessions_updated, sessions}` → update `:sessions` assign

**`handle_event`**:
- `"create_session"` — validate name, call `TmuxManager.create_session/1`, show errors on failure
- `"kill_session"` — call `TmuxManager.kill_session/1` (confirmation handled client-side)

**Template** (`session_list_live.html.heex`):
- Session cards showing: name, window count, created time, attached status
- Each session expandable to show panes (index, dimensions, running command)
- Click a pane → `push_navigate` to `/terminal/{session}:{window}.{pane}`
- "New Session" button/form — name input with validation, optional starting command
- Empty state: friendly message when no sessions, prominent "Create Session" CTA

### 4.3 Responsive Layout

**Desktop (>1024px)**:
- Sidebar with session list
- Main area placeholder (will be terminal in later phase)

**Tablet (640-1024px)**:
- Sidebar + terminal split

**Mobile (<640px)**:
- Full-width card list
- Large touch targets (min 48px height)
- "New Session" as a floating action button or full-width button at top

### 4.4 Tailwind Plus Components

Use Tailwind Plus application-ui components for:
- **Navigation shell**: sidebar + main content area
- **Card/list components**: session cards, pane list items
- **Forms**: session creation form (input, button)
- **Feedback**: flash messages, error banners
- **Empty states**: no-sessions placeholder

### 4.5 Error States & tmux Degradation

The app must handle tmux being unavailable gracefully — both at startup and if tmux dies mid-session. The goal is to surface as much diagnostic information as possible so the user knows exactly what to fix.

**SessionPoller tmux status tracking**:
- SessionPoller tracks a `:tmux_status` in its state: `:ok`, `:no_server`, `:not_found`, or `{:error, message}`
- On each poll failure, update `:tmux_status` and broadcast `{:tmux_status_changed, status}` on PubSub topic `"sessions:state"`
- On recovery (poll succeeds after failure), broadcast `{:tmux_status_changed, :ok}` on `"sessions:state"`
- `SessionPoller.tmux_status/0` — returns current status (synchronous call)

**UI error states**:

- **tmux not installed** (`{:error, :tmux_not_found}`):
  - Persistent error banner (not dismissable): "tmux is not installed or not in PATH."
  - Show diagnostic details: expected PATH locations checked, current `$PATH` value
  - Suggest: "Install tmux via your package manager (e.g., `apt install tmux`, `brew install tmux`) and restart the application."
  - All session actions disabled (create, kill, etc.)

- **tmux server not running** (`:no_server`, zero sessions):
  - Not an error — normal state. Empty state with "Create Session" CTA
  - tmux starts on demand when a session is created

- **tmux server died** (was `:ok`, now `:no_server` or `{:error, _}`):
  - Warning banner: "tmux server is no longer reachable. Sessions may have been lost."
  - Show last known error output from tmux command
  - "Retry" button that triggers `SessionPoller.force_poll/0`
  - If tmux comes back, banner auto-dismisses and sessions repopulate via normal PubSub flow

- **Session creation failure**: Flash error with the full tmux error message (not a generic "failed")

- **PaneStream with dead tmux**: PaneStreams detect tmux death via port exit + pane existence check (Phase 3). When tmux dies, all PaneStreams enter `:dead` state and broadcast `{:pane_dead, target}`. The terminal view shows "Session ended" overlay. When tmux comes back, SessionPoller detects recovery, and the user can navigate to sessions again — but dead PaneStreams are not automatically restarted (user must re-open the terminal view).

**Health check reflects tmux status**: `/healthz` returns `"tmux": "not_found"` (503) or `"tmux": "no_server"` (200, degraded) or `"tmux": "ok"` (200).

### 4.6 Logging

Key log events for SessionPoller:
- `:info` — SessionPoller started, initial poll result (session count)
- `:debug` — Poll cycle: session count, changed or unchanged
- `:warning` — tmux not reachable during poll

### 4.7 Health Check Endpoint

**`lib/remote_code_agents_web/controllers/health_controller.ex`**:
- `GET /healthz` — unauthenticated
- Calls `CommandRunner.run(["list-sessions"])` to verify tmux reachable
- Returns `200 {"status": "ok", "tmux": "ok"}` or `{"tmux": "no_server"}` or `503 {"status": "error", "tmux": "not_found"}`

### 4.8 Tests

**`test/remote_code_agents_web/live/session_list_live_test.exs`**:
- Mount page, verify sessions render
- Test "New Session" form submission (valid name, invalid name)
- Test session list updates via PubSub broadcast
- Test empty state renders correctly
- Test error state (mock tmux not found)

## Files Created/Modified
```
lib/remote_code_agents/session_poller.ex
lib/remote_code_agents_web/live/session_list_live.ex
lib/remote_code_agents_web/live/session_list_live.html.heex
lib/remote_code_agents_web/controllers/health_controller.ex
lib/remote_code_agents_web/router.ex (add routes)
test/remote_code_agents/session_poller_test.exs
test/remote_code_agents_web/live/session_list_live_test.exs
```

## Exit Criteria
- `/` shows session list pulled from tmux
- Session cards show name, windows, attached status
- Expanding a session shows its panes with dimensions and commands
- "New Session" creates a tmux session and list updates immediately
- Session list auto-updates within 3s of external changes
- Mobile layout: full-width cards, large touch targets
- Empty state renders when no sessions exist
- `/healthz` returns correct status
