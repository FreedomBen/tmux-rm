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
  idle_timer_ref: nil,           # Process.send_after ref
  last_output_at: nil,           # monotonic timestamp of last output
  had_recent_activity: false,    # true after output, false after idle broadcast
  marker_partial: <<>>           # incomplete OSC marker from previous chunk (shell integration)
}
```

**Idle detection logic in PaneStream:**

- In `flush_output/1`: set `last_output_at = System.monotonic_time(:millisecond)`, set `had_recent_activity = true`, cancel existing `idle_timer_ref`, start new timer via `Process.send_after(self(), :idle_timeout, idle_threshold_ms)`.
- New `handle_info(:idle_timeout, state)`: if `had_recent_activity` is true, broadcast `{:pane_idle, target, elapsed_ms}`, set `had_recent_activity = false`.
- Idle tracking always runs (it's cheap — just a timer reset and a `Process.send_after`). The LiveView decides whether to forward idle events to the JS hook based on the user's notification preference. This avoids complex bidirectional config sync between PaneStream and the client.

**Pros:** No user setup. Portable. Uses existing data flow.

**Cons:** Cannot provide command name, exit code, or precise timing. False positives possible (command pauses output then resumes). The idle threshold is a tradeoff — too short = false positives, too long = delayed notification.

**Configurable threshold:** Exposed in settings UI. Default 10s. Range: 3–120 seconds.

### Mode 2: Shell Integration

**How it works:**

The shell hooks write an OSC marker into the pane's own output stream via `printf`. PaneStream already receives all pane output, so no extra FIFOs, sockets, or polling is needed.

**Marker protocol:**

```
\033]termigate;cmd_done;EXIT_CODE;COMMAND_NAME;DURATION_SECS\007
```

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
    set -g __termigate_cmd_start (date +%s)
    set -g __termigate_cmd_name (string split ' ' -- $argv[1])[1]
  end
  function __termigate_postexec --on-event fish_postexec
    set -l exit_code $status
    if set -q __termigate_cmd_start
      set -l duration (math (date +%s) - $__termigate_cmd_start)
      printf '\e]termigate;cmd_done;%s;%s;%s\a' $exit_code $__termigate_cmd_name $duration
      set -e __termigate_cmd_start __termigate_cmd_name
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

## Settings UI

### Preferences (localStorage)

Add to `DEFAULTS` in `preferences.js`:

```javascript
const DEFAULTS = {
  // ...existing...
  notifications: "disabled",     // "disabled" | "activity" | "shell"
  notifyIdleThreshold: 10,       // seconds (only for activity mode)
  notifyMinDuration: 5,          // seconds — suppress notifications for fast commands (shell mode)
  notifySound: false,            // play a sound with the notification
};
```

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

### Bash version detection

When shell integration is selected, the settings page should display a note about bash compatibility. Detection happens client-side via a LiveView event that asks the server to check:

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

The hook is mounted **once per LiveView** on a dedicated invisible element (e.g. `<div id="notification-hook" phx-hook="NotificationHook" class="hidden" />`), not per-terminal. This avoids duplicate notifications in multi-pane view.

```javascript
const IDLE_COOLDOWN_MS = 30_000; // 30 seconds per-pane cooldown for activity mode

const NotificationHook = {
  mounted() {
    this._idleCooldowns = {}; // pane -> last notification timestamp
    this.handleEvent("notify_command_done", (data) => {
      const prefs = loadPrefs();
      if (prefs.notifications !== "shell") return;
      if (data.duration_seconds < prefs.notifyMinDuration) return;
      this.showNotification(data);
    });

    this.handleEvent("notify_pane_idle", (data) => {
      const prefs = loadPrefs();
      if (prefs.notifications !== "activity") return;
      // Per-pane cooldown to prevent spam with low idle thresholds
      const now = Date.now();
      const lastNotify = this._idleCooldowns[data.pane] || 0;
      if (now - lastNotify < IDLE_COOLDOWN_MS) return;
      this._idleCooldowns[data.pane] = now;
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
      silent: !loadPrefs().notifySound,
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

### Notification preference sync

Notification mode is stored in localStorage (client-side). Idle tracking always runs in PaneStream (it's cheap — just a timer reset and a `Process.send_after`). The LiveView decides whether to turn idle events into push_events based on the user's preference. This avoids complex bidirectional preference sync between PaneStream and the client.

On mount and on preference change, the JS hook pushes the notification mode to the LiveView. The NotificationHook's `mounted()` callback should include:

```javascript
// Sync preferences to server on mount
const prefs = loadPrefs();
this.pushEvent("notification_pref", { mode: prefs.notifications, threshold: prefs.notifyIdleThreshold });
```

And should listen for preference changes (e.g., via a `storage` event listener or a custom event from the settings page) to re-push when the user changes settings.

```elixir
def handle_event("notification_pref", %{"mode" => mode, "threshold" => threshold}, socket) do
  {:noreply, assign(socket, notification_mode: mode, notify_idle_threshold: threshold)}
end
```

The LiveView's `handle_info` for `{:pane_idle, ...}` checks `socket.assigns.notification_mode` and only pushes the event to JS when mode is `"activity"`.

## Implementation Plan

### Phase 1: PaneStream idle tracking

**Files:** `server/lib/termigate/pane_stream.ex`

1. Add `idle_timer_ref`, `last_output_at`, `had_recent_activity` to state.
2. In `flush_output/1`: reset idle timer, set `had_recent_activity = true`.
3. Add `handle_info(:idle_timeout, state)`: broadcast `{:pane_idle, target, elapsed_ms}` if `had_recent_activity`.
4. Cancel `idle_timer_ref` in `handle_pane_death` (alongside the existing `grace_timer_ref` cancellation) and in `terminate/2`.
5. Default idle threshold: 10 seconds (from application config).
6. Add unit tests for idle detection.

### Phase 2: OSC marker scanning

**Files:** `server/lib/termigate/pane_stream.ex`

1. Add `scan_and_strip_notifications/2` function.
2. Call from `flush_output/1` before appending to buffer: prepend `state.marker_partial` to the coalesced data, call `scan_and_strip_notifications/2`, use the returned `stripped_data` for the ring buffer and broadcast, and store the returned `marker_partial` back in state.
3. Strip OSC marker sequences from data before buffering/broadcasting.
4. Broadcast `{:command_finished, target, metadata}` when marker found.
5. Handle edge case: marker split across two coalesced chunks. `scan_and_strip_notifications/2` returns `{stripped_data, marker_partial}`. The partial is stored in PaneStream state (field `marker_partial`, default `<<>>`) and prepended to the next chunk before scanning. Max marker size is ~200 bytes, so the partial is always small.
6. Add unit tests for marker parsing, including split-marker edge cases.

### Phase 3: Preferences

**Files:** `server/assets/js/preferences.js`

1. Add `notifications`, `notifyIdleThreshold`, `notifyMinDuration`, `notifySound` to `DEFAULTS`.

### Phase 4: JS notification hook

**Files:** `server/assets/js/hooks/notification_hook.js` (new)

1. Create hook with `notify_command_done` and `notify_pane_idle` event handlers.
2. Implement `showNotification()` with `document.hasFocus()` guard.
3. Handle `notification.onclick` → `window.focus()` + `pushEvent("focus_pane")`.
4. Register hook in `app.js`.

### Phase 5: LiveView integration

**Files:** `server/lib/termigate_web/live/multi_pane_live.ex`, `server/lib/termigate_web/live/terminal_live.ex`

**Note:** `terminal_live` already subscribes to `"pane:#{target}"` in mount. `multi_pane_live` does **not** currently subscribe to per-pane topics — it subscribes to `"sessions:state"` and `"config"`. Per-pane subscriptions must be added to `multi_pane_live`, managed dynamically as panes are added/removed via `{:layout_updated, panes}`. Track subscribed panes in a `subscribed_panes` MapSet assign; on layout update, diff old vs new panes, subscribe to new ones, unsubscribe from removed ones.

Notification events (`{:pane_idle, ...}`, `{:command_finished, ...}`) are additional tuple shapes on the per-pane PubSub topic.

1. **`multi_pane_live`:** Add per-pane PubSub subscriptions. In the `{:layout_updated, panes}` handler, diff against `subscribed_panes` and subscribe/unsubscribe accordingly.
2. Add `handle_info` clauses for `{:pane_idle, ...}` and `{:command_finished, ...}` — forward as push_events to the notification hook.
3. Handle `"notification_pref"` event to store mode in assigns.
4. **`multi_pane_live` only:** Handle `"focus_pane"` event to set active pane and push `"focus_terminal"`. **`terminal_live`:** Add a no-op `"focus_pane"` handler that returns `{:noreply, socket}` — LiveView does not silently ignore unhandled `handle_event` calls; an explicit clause is required.
5. **Cleanup on unmount:** In `terminate/2`, cancel any pending idle timer refs held in assigns (if the LiveView caches them). PubSub subscriptions tied to `self()` are automatically cleaned up when the LiveView process exits, but explicitly unsubscribe from pane topics in `terminate/2` to avoid ghost notifications during navigation (e.g., user navigates away from a session page while a pane idle event is in the mailbox).

```elixir
# In both multi_pane_live.ex and terminal_live.ex
def terminate(_reason, socket) do
  # Unsubscribe from all pane topics to prevent ghost notifications
  for target <- socket.assigns[:subscribed_panes] || [] do
    Phoenix.PubSub.unsubscribe(Termigate.PubSub, "pane:#{target}")
  end
  :ok
end
```

Track subscribed panes in assigns (`subscribed_panes` MapSet) so `terminate/2` knows what to clean up.

### Phase 6: Settings UI

**Files:** `server/lib/termigate_web/live/settings_live.ex`

1. Add "Notifications" section with mode selector (radio buttons: disabled / activity / shell integration).
2. Conditional display of mode-specific options.
3. Bash version check endpoint — show warning for bash <5.1 when shell integration selected.
4. Shell snippet display with copy button per shell (bash, zsh, fish).
5. "Request permission" button + permission status display.
6. "Test notification" button.

### Phase 7: Testing

1. **PaneStream tests:** idle timer fires after threshold, resets on output, marker scanning and stripping.
2. **LiveView tests:** notification events forwarded correctly, focus_pane works.
3. **JS tests (if test framework exists):** notification hook behavior, permission handling, hasFocus guard.

## Edge Cases

- **Marker split across chunks:** PaneStream coalesces output in chunks. An OSC marker could span two chunks. Solution: `scan_and_strip_notifications/2` returns a `marker_partial` binary when it finds an incomplete marker at the end of a chunk. This partial is stored in PaneStream state (field `marker_partial`, default `<<>>`) and prepended to the next chunk before scanning. Max marker size is ~200 bytes (header + 128-char command name + digits), so the partial is always small.
- **Rapid commands:** In shell integration mode, many fast commands in succession could spam notifications. The `notifyMinDuration` preference (default 5s) filters these out — only commands running longer than the threshold trigger notifications.
- **Multiple browser tabs:** Each tab has its own LiveView and hook. Use `Notification.tag` to deduplicate — browsers replace notifications with the same tag.
- **Permission denied:** If the user denies notification permission, the settings page shows the current status and instructions for re-enabling in browser settings.
- **Pane dies during command:** If the pane dies, PaneStream shuts down. The idle timer must be cancelled in `handle_pane_death` (add `Process.cancel_timer` for `idle_timer_ref` alongside the existing `grace_timer_ref` cancellation). For shell integration, the marker never arrives, so no notification. This is acceptable — the pane death itself is visible in the UI.
- **User working in tmux directly:** Both modes will trigger notifications for commands run outside the browser. This is a feature, not a bug — the user opted in. The `document.hasFocus()` guard means they won't be interrupted if they're already looking at the termigate tab.
- **Idle timer vs coalesce delay:** PaneStream coalesces output chunks (default 3ms coalesce window). The idle timer resets in `flush_output/1`, which fires after coalescing. This means the effective idle time includes the coalesce delay. At default settings (10s idle threshold, 3ms coalesce), this is negligible. But at low idle thresholds (e.g., 3s), the coalesce delay could cause the idle timer to reset slightly late. This is acceptable — the coalesce delay is small relative to any reasonable idle threshold.
- **Notification cooldown (activity mode):** With a low idle threshold (e.g. 3s) and a pane alternating between output bursts and silence, the user could get spammed. The JS hook enforces a per-pane cooldown: after showing an idle notification for a pane, suppress further idle notifications for that pane for 30 seconds. Shell integration mode does not need this since `notifyMinDuration` already filters rapid commands.
- **Tab closed = no notifications:** The current architecture (LiveView push_event → JS hook) fundamentally requires an open tab. If the user closes all termigate tabs, no notifications fire — PaneStream still broadcasts events, but no LiveView is alive to receive them. A Service Worker with a WebSocket or SSE connection could provide persistent notifications independent of tab lifecycle, but this is a non-goal for the initial implementation. Can be revisited if users request it.
