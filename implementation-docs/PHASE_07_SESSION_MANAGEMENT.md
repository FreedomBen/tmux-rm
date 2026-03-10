# Phase 7: Session Management

## Goal
Add full session lifecycle management from the web UI: kill sessions, rename sessions, create windows, split panes, and kill panes. Adds action menus, confirmation dialogs, and inline editing to the session list.

## Dependencies
- Phase 4 complete (session list UI)
- Phase 2 complete (TmuxManager with all mutation functions)

## Steps

### 7.1 TmuxManager Mutations (verify/complete)

Ensure all mutation functions from Phase 2 are implemented and broadcast `{:sessions_changed}`:
- `kill_session/1`
- `rename_session/2` (with name validation)
- `create_window/1`
- `split_pane/2` (horizontal/vertical)
- `kill_pane/1`

### 7.2 Session List UI Enhancements

**Action menus** on session cards (kebab menu icon, or long-press on mobile):
- Rename session
- Create window
- Kill session (with confirmation)

**Pane action menus** (on each pane within expanded session card):
- Split horizontal ("Split │")
- Split vertical ("Split ─")
- Kill pane (with "x" button, confirmation dialog)

### 7.3 Confirmation Dialogs

LiveView modal component for destructive actions:
- Kill session: "Are you sure you want to kill session '{name}'? All windows and processes will be terminated."
- Kill pane: "Kill this pane? The process inside will be terminated." If it's the last pane in the session, show "This is the last pane — killing it will end the session. Kill session instead?"
- Use Tailwind Plus overlay/modal components
- Full-width buttons on mobile for easy tap targets

### 7.4 Inline Rename

- Click session name or choose "Rename" from action menu
- Inline edit component: text input replaces the name, Enter to confirm, Esc to cancel
- Name validation (`^[a-zA-Z0-9_-]+$`) with inline error message
- On success: session list updates immediately (PubSub broadcast from TmuxManager)

### 7.5 Session List Event Handlers

```elixir
# session_list_live.ex additions:

def handle_event("kill_session", %{"name" => name}, socket) do
  TmuxManager.kill_session(name)
  {:noreply, socket}
end

def handle_event("rename_session", %{"old_name" => old, "new_name" => new}, socket) do
  case TmuxManager.rename_session(old, new) do
    :ok -> {:noreply, socket}
    {:error, :invalid_name} -> {:noreply, put_flash(socket, :error, "Invalid session name")}
    {:error, reason} -> {:noreply, put_flash(socket, :error, "Rename failed: #{inspect(reason)}")}
  end
end

def handle_event("create_window", %{"session" => session}, socket) do
  TmuxManager.create_window(session)
  {:noreply, socket}
end

def handle_event("split_pane", %{"target" => target, "direction" => dir}, socket) do
  TmuxManager.split_pane(target, String.to_existing_atom(dir))
  {:noreply, socket}
end

def handle_event("kill_pane", %{"target" => target}, socket) do
  TmuxManager.kill_pane(target)
  {:noreply, socket}
end
```

### 7.6 Pane Death During Session Management

- If a viewer is watching a pane that gets killed via the session list, they receive the standard `{:pane_dead, target}` broadcast → "Session ended" overlay. No special handling needed.

### 7.7 Safety Guards

- Cannot kill the last pane in a session from the UI — detect via pane count, show "Kill session instead?" prompt
- Rename validation uses same regex as create
- All mutations trigger immediate session list refresh via PubSub

### 7.8 REST API for Session Management

**`lib/remote_code_agents_web/controllers/session_controller.ex`**:
```
GET    /api/sessions             — list sessions with panes (from SessionPoller.get/0)
POST   /api/sessions             — create session (rate limited)
DELETE /api/sessions/:name       — kill session
PUT    /api/sessions/:name       — rename session
POST   /api/sessions/:name/windows — create window
```

**`lib/remote_code_agents_web/controllers/pane_controller.ex`**:
```
POST   /api/panes/:target/split  — split pane (body: {"direction": "horizontal"|"vertical"})
DELETE /api/panes/:target        — kill pane
```

### 7.9 Tests

- Test kill session flow (confirmation → kill → list updates)
- Test rename (valid name, invalid name, duplicate name)
- Test create window (session gets a new window)
- Test split pane (horizontal, vertical)
- Test kill pane (including last-pane-in-session guard)
- Test REST API endpoints (create, delete, rename, list)

## Files Created/Modified
```
lib/remote_code_agents_web/live/session_list_live.ex (update)
lib/remote_code_agents_web/live/session_list_live.html.heex (update)
lib/remote_code_agents_web/controllers/session_controller.ex
lib/remote_code_agents_web/controllers/pane_controller.ex
lib/remote_code_agents_web/router.ex (add API routes)
test/remote_code_agents_web/live/session_list_live_test.exs (extend)
test/remote_code_agents_web/controllers/session_controller_test.exs
test/remote_code_agents_web/controllers/pane_controller_test.exs
```

## Exit Criteria
- Kill session via UI: confirmation dialog → session removed → list updates
- Rename session: inline edit → name validated → list updates with new name
- Create window: button click → new window appears in session card
- Split pane: action menu → new pane appears → can navigate to it
- Kill pane: confirmation → pane removed. Viewers on that pane see "Session ended"
- Last-pane guard shows "Kill session instead?" prompt
- REST API endpoints work for all mutations
- Session list updates reflect all changes within seconds
