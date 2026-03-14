# Notifications Design

Command completion notifications for long-running commands. When a command finishes in a tmux pane, the user receives a browser notification. Clicking the notification focuses the browser tab and the pane that triggered it.

## Feature Summary

- **Default state:** Disabled. User opts in via Settings.
- **Two detection modes** (mutually exclusive, radio/select control):
  1. **Activity Heuristic** — detects when a pane transitions from producing output to silence. Zero setup, works with any shell.
  2. **Shell Integration** — uses `precmd`/`preexec` shell hooks to precisely detect command start and finish. Requires user to add a one-liner to their shell rc file. Provides richer notifications (command name, exit code, duration).
- **Shell Integration availability:** bash ≥5.1, zsh, fish. Bash <5.1 is disallowed for shell integration (no `PROMPT_COMMAND` array; `DEBUG` trap conflicts). Activity heuristic remains available for all shells.

## Detection Mode Details

### Mode 1: Activity Heuristic

**How it works:**

PaneStream already receives all pane output via pipe-pane → FIFO → Port. We add idle tracking:

1. Each time `flush_output/1` fires (output received), reset an idle timer.
2. When the idle timer expires (configurable, default 10 seconds), broadcast `{:pane_idle, target, idle_ms}` on the existing per-pane PubSub topic (same topic used for output). No separate notification topic — the LiveView pattern-matches on the tuple shape.
3. The LiveView receives this and pushes a `"notify_idle"` event to the JS hook.
4. The JS hook shows a browser Notification.

**State additions to PaneStream:**

```elixir
%{
  # existing fields...
  notification_mode: "disabled", # "disabled" | "activity" | "shell" — from Config
  idle_timer_ref: nil,           # Process.send_after ref
  idle_threshold_ms: 10_000,     # from Config, updated on {:config_changed, _}
  last_output_at: nil,           # monotonic timestamp of last output
  had_recent_activity: false,    # true after output, false after idle broadcast
  marker_partial: <<>>           # incomplete OSC marker from previous chunk (shell integration)
}
```

**Idle detection logic in PaneStream:**

- In `flush_output/1`: set `last_output_at = System.monotonic_time(:millisecond)`, set `had_recent_activity = true`. If `notification_mode != "disabled"`: cancel existing `idle_timer_ref`, start new timer via `Process.send_after(self(), :idle_timeout, state.idle_threshold_ms)`. If `notification_mode == "disabled"`: skip timer setup.
- New `handle_info(:idle_timeout, state)`: if `had_recent_activity` is true, broadcast `{:pane_idle, target, elapsed_ms}`, set `had_recent_activity = false`.
- New `handle_info({:config_changed, config}, state)`: read `config["notifications"]["mode"]` and `config["notifications"]["idle_threshold"]`. Update `notification_mode` and `idle_threshold_ms` in state. If mode changed to `"disabled"`, cancel any active `idle_timer_ref`. If mode changed from `"disabled"` and `had_recent_activity` is true, start a new idle timer. If mode is unchanged and non-disabled, and an `idle_timer_ref` is active, cancel it and reschedule with the new threshold (adjusted for time already elapsed since `last_output_at`).
- PaneStream reads the notification mode and idle threshold from `Config.get()` on init and subscribes to the `"config"` PubSub topic. When a `{:config_changed, config}` message arrives, PaneStream updates its `notification_mode`, `idle_threshold_ms` fields and manages the idle timer accordingly: if mode changed to `"disabled"`, cancel any active timer; if mode changed from `"disabled"` and there's been recent activity, start a new timer. The LiveView provides a second gate, only forwarding idle events to the JS hook when mode is `"activity"`.

**Pros:** No user setup. Portable. Uses existing data flow.

**Cons:** Cannot provide command name, exit code, or precise timing. False positives possible (command pauses output then resumes). The idle threshold is a tradeoff — too short = false positives, too long = delayed notification.

**Configurable threshold:** Exposed in settings UI. Default 10s. Range: 3–120 seconds. PaneStream reads this from config on init and subscribes to config changes, so the timer always matches the user's setting.

### Mode 2: Shell Integration

**How it works:**

The shell hooks write an OSC marker into the pane's own output stream via `printf`. PaneStream already receives all pane output, so no extra FIFOs, sockets, or polling is needed.

**Marker protocol:**

```
\e]termigate;cmd_done;EXIT_CODE;COMMAND_NAME;DURATION_SECS\a
```

(Uses `\e` for ESC / `\a` for BEL throughout. Shell snippets use the equivalent `\033`/`\007` or `\e`/`\a` as appropriate for each shell.)

This uses an OSC (Operating System Command) escape sequence with a custom identifier `termigate`. xterm.js will ignore unrecognized OSC sequences, so they won't render visually. PaneStream scans the output byte stream for this marker.

**Shell hook snippets** (displayed on Settings page, user copies to their rc file):

**bash ≥5.1:**

Note on `DEBUG` trap: While bash 5.1+ has `PROMPT_COMMAND` arrays, the `DEBUG` trap is still last-writer-wins. The snippet below chains with any existing DEBUG trap to avoid clobbering it.

```bash
# Termigate notifications — add to ~/.bashrc
if [ -n "$TMUX_PANE" ]; then
  __termigate_precmd() {
    local exit_code=$?
    local duration=$(( SECONDS - ${__termigate_cmd_start:-$SECONDS} ))
    if [ -n "$__termigate_cmd_start" ]; then
      printf '\033]termigate;cmd_done;%s;%s;%s\007' "$exit_code" "${__termigate_cmd_name:-unknown}" "$duration"
    fi
    unset __termigate_cmd_start __termigate_cmd_name
  }
  __termigate_preexec() {
    # Only set if not already in a precmd cycle
    if [ -z "$__termigate_cmd_start" ]; then
      __termigate_cmd_start=$SECONDS
      __termigate_cmd_name="${BASH_COMMAND%% *}"
    fi
  }
  PROMPT_COMMAND+=(__termigate_precmd)
  # Chain with existing DEBUG trap
  __termigate_prev_trap=$(trap -p DEBUG)
  trap '__termigate_preexec; '"${__termigate_prev_trap:+${__termigate_prev_trap#trap -- }}" DEBUG
fi
```

**zsh:**
```zsh
# Termigate notifications — add to ~/.zshrc
if [[ -n "$TMUX_PANE" ]]; then
  __termigate_preexec() {
    __termigate_cmd_start=$SECONDS
    __termigate_cmd_name="${1%% *}"
  }
  __termigate_precmd() {
    local exit_code=$?
    if [[ -n "$__termigate_cmd_start" ]]; then
      local duration=$(( SECONDS - __termigate_cmd_start ))
      printf '\033]termigate;cmd_done;%s;%s;%s\007' "$exit_code" "$__termigate_cmd_name" "$duration"
      unset __termigate_cmd_start __termigate_cmd_name
    fi
  }
  precmd_functions+=(__termigate_precmd)
  preexec_functions+=(__termigate_preexec)
fi
```

**fish:**
```fish
# Termigate notifications — add to ~/.config/fish/config.fish
if set -q TMUX_PANE
  function __termigate_preexec --on-event fish_preexec
    set -g __termigate_cmd_name (string split ' ' -- $argv[1])[1]
  end
  function __termigate_postexec --on-event fish_postexec
    set -l exit_code $status
    # $CMD_DURATION is set by fish after each command (milliseconds)
    set -l duration (math "$CMD_DURATION / 1000")
    if set -q __termigate_cmd_name
      printf '\e]termigate;cmd_done;%s;%s;%s\a' $exit_code $__termigate_cmd_name $duration
      set -e __termigate_cmd_name
    end
  end
end
```

**Why these are safe:**
- All hooks guard on `$TMUX_PANE` — no-op outside tmux.
- zsh: `precmd_functions`/`preexec_functions` arrays are additive by design. No conflict.
- fish: Event system is additive by design. No conflict.
- bash ≥5.1: `PROMPT_COMMAND` array is additive. `DEBUG` trap chains with any existing trap.
- All output goes to the pane's stdout which PaneStream already reads. No extra FIFOs or sockets needed.
- If termigate is not watching the pane, the OSC sequences are silently produced and discarded.

**PaneStream marker scanning:**

In `flush_output/1`, after building the binary, call `scan_and_strip_notifications/2` which both broadcasts notification events and returns the data with OSC markers stripped. The stripped data is what gets appended to the ring buffer and broadcast to viewers.

```elixir
@notification_marker "\e]termigate;"

# Returns {stripped_data, marker_partial}
# Strips all termigate OSC markers from the data and broadcasts notification events.
# marker_partial is stored in PaneStream state and prepended to the next chunk.
defp scan_and_strip_notifications(data, target) do
  do_scan_and_strip(data, target, <<>>)
end

defp do_scan_and_strip(data, target, acc) do
  case :binary.match(data, @notification_marker) do
    {start, len} ->
      # Keep everything before the marker
      before = binary_part(data, 0, start)
      rest = binary_part(data, start + len, byte_size(data) - start - len)
      case :binary.match(rest, <<7>>) do
        {end_pos, _} ->
          payload = binary_part(rest, 0, end_pos)
          parse_and_broadcast_notification(payload, target)
          remaining = binary_part(rest, end_pos + 1, byte_size(rest) - end_pos - 1)
          do_scan_and_strip(remaining, target, <<acc::binary, before::binary>>)
        :nomatch ->
          # Incomplete marker at end of chunk — store in marker_partial state
          # for prepending to next chunk. Return acc + before as stripped data.
          {<<acc::binary, before::binary>>, binary_part(data, start, byte_size(data) - start)}
      end
    :nomatch ->
      {<<acc::binary, data::binary>>, <<>>}
  end
end

defp parse_and_broadcast_notification(payload, target) do
  case String.split(payload, ";") do
    ["cmd_done", exit_code, cmd_name, duration] ->
      # Sanitize command name: truncate and restrict to printable ASCII
      sanitized_name = cmd_name
        |> String.slice(0, 128)
        |> String.replace(~r/[^\x20-\x7E]/, "")

      with {parsed_exit_code, _} <- Integer.parse(exit_code),
           {parsed_duration, _} <- Integer.parse(duration) do
        broadcast(target, {:command_finished, target, %{
          exit_code: parsed_exit_code,
          command: sanitized_name,
          duration_seconds: parsed_duration
        }})
      end
    _ -> :ok  # Ignore malformed markers (wrong field count or non-integer values)
  end
end
```

The return value is `{stripped_data, marker_partial}`. `stripped_data` is safe to buffer/broadcast. `marker_partial` is stored in state and prepended to the next chunk to handle markers split across chunks (see Edge Cases).

## Settings

### Config file (YAML)

Notification settings are stored in the YAML config file (`~/.config/termigate/config.yaml`), not in localStorage. This ensures settings survive browser changes and are consistent across tabs/devices.

Add a top-level `notifications` section to the config schema:

```yaml
notifications:
  mode: "disabled"          # "disabled" | "activity" | "shell"
  idle_threshold: 10        # seconds (activity mode) — range: 3–120
  min_duration: 5           # seconds (shell mode) — suppress fast commands
  sound: false              # play a sound with the notification
```

**Default config** (added to `@default_config` in `config.ex`):

```elixir
@default_config %{
  # ...existing...
  "notifications" => %{
    "mode" => "disabled",
    "idle_threshold" => 10,
    "min_duration" => 5,
    "sound" => false
  }
}
```

**Validation** (in `config.ex`):

```elixir
defp clamp(value, min_val, max_val) when is_number(value), do: max(min_val, min(max_val, value))
defp clamp(_value, min_val, _max_val), do: min_val

defp normalize_notifications_section(config) do
  defaults = @default_config["notifications"]
  notif = Map.merge(defaults, config["notifications"] || %{})

  notif = %{
    "mode" => if(notif["mode"] in ~w(disabled activity shell), do: notif["mode"], else: "disabled"),
    "idle_threshold" => notif["idle_threshold"] |> clamp(3, 120),
    "min_duration" => notif["min_duration"] |> clamp(0, 600),
    "sound" => notif["sound"] == true
  }

  Map.put(config, "notifications", notif)
end
```

Normalization runs both on config load and on `Config.update/1` — the update callback's return value is passed through the full normalization pipeline before being persisted and broadcast. This ensures invalid values from the settings UI are clamped/coerced.

### Config → LiveView → JS flow

The LiveView reads notification config on mount and pushes it to the JS hook. When the user changes settings, the LiveView writes to Config, which broadcasts `{:config_changed, config}` — all connected LiveViews pick up the change.

```elixir
# In mount, after Config.get():
notification_config = config["notifications"] || %{}
socket = assign(socket, notification_config: notification_config)
```

The LiveView pushes notification config to the JS hook on mount and on config change:

```elixir
defp push_notification_config(socket) do
  push_event(socket, "notification_config", %{config: socket.assigns.notification_config})
end
```

The JS hook receives this and uses it for notification decisions (instead of reading localStorage).

### Settings page section

Add a "Notifications" section to `settings_live.ex` with:

1. **Mode selector** — radio buttons or a `<select>`:
   - Disabled (default)
   - Activity-based (silence detection)
   - Shell integration (requires setup)

2. **Activity mode options** (shown when activity mode selected):
   - Idle threshold slider: 3–120 seconds, default 10

3. **Shell integration options** (shown when shell mode selected):
   - Minimum duration: don't notify for commands shorter than N seconds (default 5)
   - Shell setup instructions: collapsible section showing the appropriate snippet for bash/zsh/fish
   - A "Test notification" button

4. **Common options** (shown when any mode except disabled is selected):
   - Notification sound toggle
   - "Request permission" button (calls `Notification.requestPermission()`). Note: modern browsers require permission requests to originate from a user gesture (e.g., button click). The button satisfies this requirement. Do not call `requestPermission()` programmatically on page load — it will be silently blocked.
   - Permission status indicator

**Settings save handler:**

```elixir
def handle_event("update_notification_setting", %{"key" => key, "value" => value}, socket) do
  Config.update(fn config ->
    notif = Map.get(config, "notifications", %{})
    Map.put(config, "notifications", Map.put(notif, key, value))
  end)

  {:noreply, socket}
end
```

### Bash version detection

When shell integration is selected, the settings page should display a note about bash compatibility. Detection happens via a LiveView event that asks the server to check:

```elixir
def handle_event("check_bash_version", _, socket) do
  version = case System.cmd("bash", ["--version"], stderr_to_stdout: true) do
    {output, 0} ->
      case Regex.run(~r/version (\d+)\.(\d+)/, output) do
        [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
        _ -> :unknown
      end
    _ -> :unknown
  end

  bash_ok = case version do
    {major, _minor} when major > 5 -> true
    {5, minor} when minor >= 1 -> true
    _ -> false
  end

  {:noreply, assign(socket, bash_version: version, bash_shell_integration_ok: bash_ok)}
end
```

If bash <5.1, show a warning in the shell integration section and recommend using zsh/fish or the activity heuristic instead.

## Browser Notification Flow

### JS notification hook (`server/assets/js/hooks/notification_hook.js`)

The hook is mounted **once per LiveView** on a dedicated invisible element in `multi_pane_live.html.heex`: `<div id="notification-hook" phx-hook="NotificationHook" class="hidden" />`. Placed once per template, not per-terminal. This avoids duplicate notifications in multi-pane view.

```javascript
const IDLE_COOLDOWN_MS = 30_000; // 30 seconds per-pane cooldown for activity mode

const NotificationHook = {
  mounted() {
    this._idleCooldowns = {}; // pane -> last notification timestamp
    this._config = {};         // populated by server push

    // Receive notification config from server (on mount and on config change)
    this.handleEvent("notification_config", ({ config }) => {
      this._config = config;
    });

    this.handleEvent("notify_command_done", (data) => {
      if (this._config.mode !== "shell") return;
      if (data.duration_seconds < (this._config.min_duration || 5)) return;
      this.showNotification(data);
    });

    this.handleEvent("notify_pane_idle", (data) => {
      if (this._config.mode !== "activity") return;
      // Per-pane cooldown to prevent spam with low idle thresholds
      const now = Date.now();
      const lastNotify = this._idleCooldowns[data.pane] || 0;
      if (now - lastNotify < IDLE_COOLDOWN_MS) return;
      this._idleCooldowns[data.pane] = now;
      // Prune stale cooldown entries to prevent unbounded growth over long sessions
      for (const [pane, ts] of Object.entries(this._idleCooldowns)) {
        if (now - ts > IDLE_COOLDOWN_MS * 2) delete this._idleCooldowns[pane];
      }
      this.showNotification(data);
    });
  },

  showNotification(data) {
    if (Notification.permission !== "granted") return;
    if (document.hasFocus()) return; // Don't notify if tab is focused

    const title = data.command
      ? `Command finished: ${data.command}`
      : `Activity stopped in pane`;

    const body = data.command
      ? `Exit code: ${data.exit_code} | Duration: ${data.duration_seconds}s`
      : `Pane ${data.pane} has been idle for ${data.idle_seconds}s`;

    const notification = new Notification(title, {
      body: body,
      tag: `termigate-${data.pane}`, // Replace previous notification for same pane
      icon: "/favicon.ico",
      silent: !(this._config.sound),
    });

    notification.onclick = () => {
      window.focus();
      // Push event to LiveView to focus the pane
      this.pushEvent("focus_pane", { pane: data.pane });
      notification.close();
    };
  },
};
```

### Tab focus behavior

`notification.onclick`:
1. `window.focus()` — brings the browser tab to front.
2. `this.pushEvent("focus_pane", { pane: data.pane })` — tells the LiveView which pane to activate.
3. LiveView handles `"focus_pane"` by setting `active_pane` in assigns and pushing a `"focus_terminal"` event to the terminal hook.

In `multi_pane_live.ex`:

```elixir
def handle_event("focus_pane", %{"pane" => pane_target}, socket) do
  # If maximized on a different pane, unmaximize first
  socket = if socket.assigns.maximized && socket.assigns.maximized != pane_target do
    assign(socket, maximized: nil)
  else
    socket
  end

  {:noreply, assign(socket, active_pane: pane_target) |> push_event("focus_terminal", %{pane: pane_target})}
end
```

### `document.hasFocus()` guard

Don't show notifications when the user is actively looking at the tab. This prevents annoying popups when the user is already watching the terminal. Only notify when the tab is in the background.

## Server-Side Event Flow

### Activity heuristic path

```
PaneStream (flush_output)
  → reset idle timer
  → [idle_threshold seconds pass]
  → handle_info(:idle_timeout)
  → PubSub broadcast {:pane_idle, target, idle_ms}
  → LiveView handle_info (converts ms → seconds)
  → push_event "notify_pane_idle" with %{pane: target, idle_seconds: idle_ms / 1000}
  → JS NotificationHook.showNotification()
```

### Shell integration path

```
Shell hook (printf OSC sequence)
  → tmux pipe-pane → FIFO → PaneStream Port
  → flush_output scans for marker
  → PubSub broadcast {:command_finished, target, metadata}
  → LiveView handle_info
  → push_event "notify_command_done"
  → JS NotificationHook.showNotification()
```

### Notification config sync

Notification settings are stored server-side in the config file. The LiveView reads them on mount from `Config.get()` and subscribes to the `"config"` PubSub topic. When settings change (via the settings page or config file edit), the `{:config_changed, config}` broadcast updates all connected LiveViews, which push the new config to the JS hook via `push_event("notification_config", ...)`.

Idle tracking in PaneStream is gated on the notification mode. PaneStream reads the mode from config on init and on `{:config_changed, _}`. When mode is `"disabled"`, PaneStream skips idle timer setup entirely and cancels any active timer. When mode is `"activity"` or `"shell"`, idle tracking runs (it's cheap — just a timer reset and a `Process.send_after`). The LiveView provides a second gate, only forwarding idle events as push_events when mode is `"activity"`. This avoids unnecessary timers when notifications are disabled while keeping the LiveView as a defense-in-depth check.

```elixir
# In handle_info for {:config_changed, config}
def handle_info({:config_changed, config}, socket) do
  notification_config = config["notifications"] || %{}
  socket = assign(socket, notification_config: notification_config)
  {:noreply, push_notification_config(socket)}
end
```

The notification mode is checked in three places (defense-in-depth): PaneStream only runs idle timers when mode is not `"disabled"` (avoids unnecessary work). The LiveView's `handle_info` for `{:pane_idle, ...}` checks `socket.assigns.notification_config["mode"]` and only pushes the event to JS when mode is `"activity"` (server-side gate to avoid unnecessary push_events). The JS hook also checks `this._config.mode` before showing a notification (client-side safety net in case of race between config change and in-flight events).

## Implementation Plan

### Phase 1: PaneStream idle tracking ✅ COMPLETED

**Files:** `server/lib/termigate/pane_stream.ex`

1. ✅ Add `notification_mode`, `idle_timer_ref`, `idle_threshold_ms`, `last_output_at`, `had_recent_activity` to state.
2. ✅ In `init/1`: read notification mode and idle threshold from `Config.get()["notifications"]`. Subscribe to `"config"` PubSub topic.
3. ✅ In `flush_output/1`: set `had_recent_activity = true`, `last_output_at`. Only reset/start idle timer if `notification_mode != "disabled"`.
4. ✅ Add `handle_info(:idle_timeout, state)`: broadcast `{:pane_idle, target, elapsed_ms}` if `had_recent_activity`.
5. ✅ Add `handle_info({:config_changed, config}, state)`: update `notification_mode` and `idle_threshold_ms`. If mode changed to `"disabled"`, cancel active timer. If mode changed from `"disabled"` and recent activity exists, start timer. If mode unchanged and non-disabled, reschedule with new threshold (adjusted for elapsed time).
6. ✅ Cancel `idle_timer_ref` in `handle_pane_death` (alongside the existing `grace_timer_ref` cancellation) and in `terminate/2`.
7. ✅ Add unit tests for idle detection, including threshold changes mid-timer and mode transitions. (`test/termigate/pane_stream_idle_test.exs`)

### Phase 2: OSC marker scanning ✅ COMPLETED

**Files:** `server/lib/termigate/pane_stream.ex`

1. ✅ Add `scan_and_strip_notifications/2` function.
2. ✅ Call from `flush_output/1` before appending to buffer: prepend `state.marker_partial` to the coalesced data, call `scan_and_strip_notifications/2`, use the returned `stripped_data` for the ring buffer and broadcast, and store the returned `marker_partial` back in state.
3. ✅ Strip OSC marker sequences from data before buffering/broadcasting.
4. ✅ Broadcast `{:command_finished, target, metadata}` when marker found.
5. ✅ Handle edge case: marker split across two coalesced chunks. `scan_and_strip_notifications/2` returns `{stripped_data, marker_partial}`. The partial is stored in PaneStream state (field `marker_partial`, default `<<>>`) and prepended to the next chunk before scanning. Max marker size is ~200 bytes, so the partial is always small. Staleness guard discards partials >256 bytes.
6. ✅ Tests added in `test/termigate/pane_stream_marker_test.exs` (6 tests: detection, stripping, non-zero exit codes, malformed markers, multiple markers, command name sanitization).

### Phase 3: Config schema ✅ COMPLETED

**Files:** `server/lib/termigate/config.ex`

1. ✅ Add `"notifications"` section to `@default_config` with keys: `mode`, `idle_threshold`, `min_duration`, `sound`.
2. ✅ Add `normalize_notifications_section/1` validation (mode whitelist, threshold clamping, boolean coercion). Note: `clamp/3` already exists in `config.ex`.
3. ✅ Add `|> normalize_notifications_section()` to the existing `normalize_config/1` pipeline (which already chains `normalize_terminal_section/1`).
4. ✅ Include `"notifications"` in `to_yaml/1` serialization (alongside `"terminal"` and `"auth"`).
5. ✅ Tests added in `test/termigate/config_test.exs` (notifications config describe block).

### Phase 4: JS notification hook ✅ COMPLETED

**Files:** `server/assets/js/hooks/notification_hook.js` (new)

1. ✅ Create hook with `notification_config`, `notify_command_done`, and `notify_pane_idle` event handlers.
2. ✅ Store server-pushed config in `this._config`; use it for all notification decisions (no localStorage reads).
3. ✅ Implement `showNotification()` with `document.hasFocus()` guard.
4. ✅ Handle `notification.onclick` → `window.focus()` + `pushEvent("focus_pane")`.
5. ✅ Register hook in `app.js`.

### Phase 5: LiveView integration ✅ COMPLETED

**Files:** `server/lib/termigate_web/live/multi_pane_live.ex`

1. ✅ Add per-pane PubSub subscriptions on mount. In the `{:layout_updated, panes}` handler, diff against `subscribed_panes` MapSet and subscribe/unsubscribe accordingly.
2. ✅ Add `handle_info` clauses for `{:pane_idle, ...}` and `{:command_finished, ...}` — forward as push_events to the notification hook. Check `notification_config["mode"]` before pushing (only push idle events in `"activity"` mode, only push command events in `"shell"` mode).
3. ✅ On mount, read notification config from `Config.get()`, store in assigns, and push to JS hook via `push_event("notification_config", ...)`.
4. ✅ In the existing `{:config_changed, config}` handler, update `notification_config` in assigns and re-push to JS hook.
5. ✅ Handle `"focus_pane"` event to set active pane, unmaximize if needed, and push `"focus_terminal"`.
6. ✅ Cleanup on unmount: `terminate/2` unsubscribes from pane topics. Invisible `<div id="notification-hook" phx-hook="NotificationHook">` element added to template.

### Phase 6: Settings UI ✅ COMPLETED

**Files:** `server/lib/termigate_web/live/settings_live.ex`, `settings_live.html.heex`

1. ✅ Add "Notifications" section with mode selector (radio buttons: disabled / activity / shell integration).
2. ✅ Conditional display of mode-specific options (idle threshold slider for activity, min duration slider + shell snippets for shell integration).
3. ✅ Bash version check — show warning for bash <5.1 when shell integration selected.
4. ✅ Shell snippet display in collapsible section per shell (bash, zsh, fish). Snippets stored as module attributes using `~S` sigil to avoid HEEx interpolation conflicts.
5. ✅ "Request permission" button + permission status display via `NotificationPermission` JS hook.
6. ✅ "Test notification" button. Sound toggle. All settings saved via `Config.update/1` with normalization.

### Phase 7: Testing ✅ COMPLETED

1. ✅ **PaneStream tests:** idle timer fires after threshold, resets on output, skipped when disabled, mode transitions, marker scanning and stripping. (`pane_stream_idle_test.exs`, `pane_stream_marker_test.exs` — completed in Phases 1-2)
2. ✅ **LiveView tests (`multi_pane_live`):** notification events forwarded correctly (activity + shell modes), events ignored when wrong mode, focus_pane with unmaximize, per-pane subscription management on layout update.
3. ✅ **Settings LiveView tests:** mode selector rendering, conditional UI display (activity options, shell options, disabled state), config persistence for mode/idle_threshold/sound, test notification event.
4. **JS tests:** No JS test framework in project — JS hook behavior verified via manual testing and server-side integration tests.

## Edge Cases

- **Marker split across chunks:** PaneStream coalesces output in chunks. An OSC marker could span two chunks. Solution: `scan_and_strip_notifications/2` returns a `marker_partial` binary when it finds an incomplete marker at the end of a chunk. This partial is stored in PaneStream state (field `marker_partial`, default `<<>>`) and prepended to the next chunk before scanning. Max marker size is ~200 bytes (header + 128-char command name + digits), so the partial is always small. **Staleness guard:** If `marker_partial` exceeds 256 bytes without a closing BEL (`\a`), discard it — it was likely a false match on `\e]termigate;` in user output rather than a real marker. In `flush_output/1`, before prepending: `marker_partial = if byte_size(state.marker_partial) > 256, do: <<>>, else: state.marker_partial`.
- **Rapid commands:** In shell integration mode, many fast commands in succession could spam notifications. The `min_duration` preference (default 5s) filters these out — only commands running longer than the threshold trigger notifications.
- **Multiple browser tabs:** Each tab has its own LiveView and hook. Use `Notification.tag` to deduplicate — browsers replace notifications with the same tag.
- **Permission denied:** If the user denies notification permission, the settings page shows the current status and instructions for re-enabling in browser settings.
- **Pane dies during command:** If the pane dies, PaneStream shuts down. The idle timer must be cancelled in `handle_pane_death` (add `Process.cancel_timer` for `idle_timer_ref` alongside the existing `grace_timer_ref` cancellation). For shell integration, the marker never arrives, so no notification. This is acceptable — the pane death itself is visible in the UI.
- **User working in tmux directly:** Both modes will trigger notifications for commands run outside the browser. This is a feature, not a bug — the user opted in. The `document.hasFocus()` guard means they won't be interrupted if they're already looking at the termigate tab.
- **Idle timer vs coalesce delay:** PaneStream coalesces output chunks (default 3ms coalesce window). The idle timer resets in `flush_output/1`, which fires after coalescing. This means the effective idle time includes the coalesce delay. At default settings (10s idle threshold, 3ms coalesce), this is negligible. But at low idle thresholds (e.g., 3s), the coalesce delay could cause the idle timer to reset slightly late. This is acceptable — the coalesce delay is small relative to any reasonable idle threshold.
- **Notification cooldown (activity mode):** With a low idle threshold (e.g. 3s) and a pane alternating between output bursts and silence, the user could get spammed. The JS hook enforces a per-pane cooldown: after showing an idle notification for a pane, suppress further idle notifications for that pane for 30 seconds. Shell integration mode does not need this since `min_duration` already filters rapid commands. Note: the server-side LiveView does not apply its own cooldown — it forwards all qualifying idle events to the JS hook, which handles deduplication. This keeps the server stateless with respect to notification history, at the cost of unnecessary push_events during the cooldown window. Acceptable since these are small, infrequent messages.
- **Tab closed = no notifications:** The current architecture (LiveView push_event → JS hook) fundamentally requires an open tab. If the user closes all termigate tabs, no notifications fire — PaneStream still broadcasts events, but no LiveView is alive to receive them. A Service Worker with a WebSocket or SSE connection could provide persistent notifications independent of tab lifecycle, but this is a non-goal for the initial implementation. Can be revisited if users request it.
