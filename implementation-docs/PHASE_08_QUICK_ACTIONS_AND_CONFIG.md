# Phase 8: Quick Actions & Config System

## Goal
Implement the `Config` GenServer, YAML config file management, quick action buttons in the terminal view, and the Settings UI for managing quick actions. After this phase, users can configure command buttons that appear above the terminal for one-tap execution.

## Dependencies
- Phase 5 complete (terminal view)
- `yaml_elixir` and `ymlr` dependencies (Phase 1)

## Steps

### 8.1 Config GenServer

**`lib/remote_code_agents/config.ex`**:

Implement the full GenServer as specified in APPLICATION_DESIGN.md (the design doc includes complete code). Key points:

- **Location**: `$RCA_CONFIG_PATH` env var → `~/.config/remote_code_agents/config.yaml` → defaults
- **Startup**: Read + validate config file. Generate missing IDs and rewrite if needed. If no file exists, write default config (empty quick_actions list).
- **File change detection**: Poll mtime every 2s (`config_poll_interval`). Re-read on change, broadcast `{:config_changed, config}` on PubSub topic `"config"`.
- **Reads**: `Config.get/0` — synchronous GenServer.call, returns in-memory config
- **Writes**: `Config.update/1` — takes `(config -> config)` function, writes atomically (tmp + rename), updates mtime, broadcasts change
- **Convenience**: `upsert_action/1`, `delete_action/1`, `reorder_actions/1`
- **Malformed file**: Keep last good config in memory, log warning
- **Deleted file**: Keep last good config, recreate on next write
- **PubSub topic**: `"config"`

### 8.2 Quick Action Schema

Each quick action has:
| Field | Type | Required | Default |
|-------|------|----------|---------|
| `id` | string | auto-generated | URL-safe random token |
| `label` | string | yes | — |
| `command` | string | yes | — (max 4096 bytes) |
| `confirm` | boolean | no | `false` |
| `color` | string | no | `"default"` (one of: default, green, red, yellow, blue) |
| `icon` | string | no | `nil` (one of: rocket, play, stop, trash, arrow-up, terminal) |

### 8.3 YAML Serialization

`to_yaml/1` produces clean YAML with header comment:
```yaml
# tmux-rm configuration
# Edit this file directly or use the web UI at /settings
#
# Quick actions appear as buttons above the terminal.
# Fields: label (required), command (required), confirm, color, icon

quick_actions:
  - id: "abc123"
    label: "Status"
    command: "git status"
```

Uses `ymlr` for encoding. Nil fields omitted. Header comment prepended.

### 8.4 Quick Action Bar in Terminal View

**Update `terminal_live.ex`**:
- On mount: subscribe to PubSub `"config"`, fetch config via `Config.get/0`
- Assign `:quick_actions` from config
- `handle_info({:config_changed, config})` → update `:quick_actions` assign

**Update `terminal_live.html.heex`**:
- Render quick action bar between header and terminal (only if actions exist)
- Horizontally scrollable on mobile (`overflow-x: auto; scroll-snap-type: x mandatory`)
- Pill-style buttons with color-coded classes
- `⚠` indicator on confirm-required actions
- Collapsible via chevron toggle

### 8.5 Quick Action Execution

**Event handlers in `terminal_live.ex`**:

- `"quick_action"` — find action by ID, check `confirm` flag:
  - If `confirm: false`: send immediately
  - If `confirm: true`: assign `:pending_action`, show confirmation modal

- `"confirm_action"` — send the pending action, clear `:pending_action`

- `"cancel_action"` — clear `:pending_action`

- `send_quick_action/2` — append `"\n"` to command, call `PaneStream.send_keys(target, command_with_enter)`

### 8.6 Confirmation Modal

LiveView modal for confirm-required actions:
- Shows "Run this command?" with the command in a code block
- "Run" and "Cancel" buttons
- Full-width buttons on mobile
- Uses Tailwind Plus overlay component

### 8.7 Settings LiveView

**`lib/remote_code_agents_web/live/settings_live.ex`**:

- Route: `/settings`
- Mount: subscribe to PubSub `"config"`, fetch config
- Displays list of configured quick actions with edit/delete buttons
- "Add Quick Action" button opens a form
- Form fields: label, command, color dropdown, confirm checkbox
- Drag-to-reorder (via JS interop / `phx-hook` for sortable)
- All changes go through `Config.upsert_action/1`, `Config.delete_action/1`, `Config.reorder_actions/1`
- PubSub broadcasts keep the view in sync with external edits

**`lib/remote_code_agents_web/live/settings_live.html.heex`**:
- Quick action list with edit/delete controls
- Add/edit form with validation
- Mobile-friendly: full-screen panel with large touch targets
- Uses Tailwind Plus form and list components

### 8.8 REST API for Quick Actions

**`lib/remote_code_agents_web/controllers/config_controller.ex`**:
- `GET /api/config` — returns full config as JSON

**`lib/remote_code_agents_web/controllers/quick_action_controller.ex`**:
- `GET /api/quick-actions` — list quick actions
- `POST /api/quick-actions` — create (returns full list with generated ID)
- `PUT /api/quick-actions/:id` — update by stable ID
- `DELETE /api/quick-actions/:id` — delete by stable ID
- `PUT /api/quick-actions/order` — reorder (body: `{"ids": [...]}`)

All endpoints require bearer token auth.

### 8.9 Router Updates

```elixir
# In authenticated API scope:
get "/config", ConfigController, :show
put "/quick-actions/order", QuickActionController, :reorder
resources "/quick-actions", QuickActionController, only: [:index, :create, :update, :delete]
```

### 8.10 Tests

- Config GenServer: startup (file exists, file missing, malformed file), get/update, mtime polling, PubSub broadcast
- Quick action CRUD: create, update, delete, reorder (including ID mismatch error)
- YAML round-trip: write + read preserves data
- Terminal view: quick action bar renders, click triggers send_keys, confirmation flow
- Settings UI: add/edit/delete quick actions
- REST API: all endpoints with valid/invalid inputs

## Files Created/Modified
```
lib/remote_code_agents/config.ex
lib/remote_code_agents_web/live/terminal_live.ex (update)
lib/remote_code_agents_web/live/terminal_live.html.heex (update)
lib/remote_code_agents_web/live/settings_live.ex
lib/remote_code_agents_web/live/settings_live.html.heex
lib/remote_code_agents_web/controllers/config_controller.ex
lib/remote_code_agents_web/controllers/quick_action_controller.ex
lib/remote_code_agents_web/router.ex (update)
test/remote_code_agents/config_test.exs
test/remote_code_agents_web/live/settings_live_test.exs
test/remote_code_agents_web/controllers/quick_action_controller_test.exs
```

## Exit Criteria
- Config file auto-created on first boot with defaults
- Quick actions defined in YAML appear as buttons above terminal
- Tapping a quick action sends the command to the terminal
- Confirm-required actions show modal before executing
- Settings UI: add, edit, delete, reorder quick actions
- Hand-editing the YAML file reflects in the UI within 2s
- REST API: full CRUD for quick actions
- Config changes broadcast to all connected viewers
- Malformed YAML keeps last good config, logs warning
