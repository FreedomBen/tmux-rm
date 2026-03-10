# Phase 5: Terminal View Web UI

## Goal
Implement `TerminalLive` and the `TerminalHook` JavaScript module. After this phase, users can click a pane in the session list and get a full-viewport interactive terminal in the browser with real-time streaming output and keyboard input.

## Dependencies
- Phase 3 complete (PaneStream)
- Phase 4 complete (session list with navigation)
- xterm.js npm packages installed (Phase 1)

## Steps

### 5.1 TerminalHook (JavaScript)

**`assets/js/hooks/terminal_hook.js`**:

**`mounted()`**:
1. Create xterm.js `Terminal` instance with options from localStorage preferences:
   ```javascript
   const prefs = JSON.parse(localStorage.getItem('rca-preferences') || '{}');
   const term = new Terminal({
     fontSize: prefs.fontSize || 14,
     fontFamily: prefs.fontFamily || 'monospace',
     theme: prefs.theme || {},
     cursorStyle: prefs.cursorStyle || 'block',
     cursorBlink: prefs.cursorBlink !== false,
     scrollback: prefs.scrollback || 10000,
   });
   ```
2. Create and load `FitAddon`, optionally `WebLinksAddon`
3. Open terminal in container div: `term.open(this.el)`
4. Call `fitAddon.fit()`
5. Send initial resize: `this.pushEvent("resize", {cols: term.cols, rows: term.rows})`

**`onData` handler** (keyboard input):
- Buffer keystrokes in a local array
- Flush every 16ms (via `requestAnimationFrame`) or when buffer exceeds 64 bytes
- On flush: concatenate bytes, encode to UTF-8 via `TextEncoder`, base64-encode, send `this.pushEvent("key_input", {data: base64String})`

**`onResize` handler**:
- Debounce 300ms
- Send `this.pushEvent("resize", {cols, rows})`

**Server event handlers**:
- `this.handleEvent("output", ({data}) => { ... })` — base64 decode, `term.write(bytes)`
- `this.handleEvent("history", ({data}) => { ... })` — base64 decode, `term.write(bytes)` (initial scrollback)
- `this.handleEvent("reconnected", ({data}) => { ... })` — `term.reset()`, base64 decode, `term.write(bytes)`
- `this.handleEvent("pane_dead", () => { ... })` — display "Session ended" overlay with link back to session list

**Clipboard**:
- Copy: user selects text in terminal, uses Ctrl+Shift+C (or right-click → Copy) to copy. No auto-copy on selection (browsers gate clipboard writes behind user gestures in secure contexts, and auto-copy is disruptive).
- Paste: intercept Ctrl+Shift+V → `navigator.clipboard.readText()` → send as `"key_input"` event
- Fallback to `document.execCommand` for older browsers

**`destroyed()`**:
- Dispose xterm.js instance
- Cancel any pending timers

### 5.2 Register Hook in app.js

**`assets/js/app.js`**:
```javascript
import { TerminalHook } from "./hooks/terminal_hook";

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { TerminalHook },
  // ...
});
```

### 5.3 TerminalLive (Server)

**`lib/remote_code_agents_web/live/terminal_live.ex`**:

**`mount/3`**:
1. Parse target from URL params: `"#{session}:#{window}.#{pane}"`
2. Call `PaneStream.subscribe(target)` → `{:ok, history, pane_stream_pid}` or `{:error, reason}`
3. On success:
   - Monitor `pane_stream_pid` via `Process.monitor/1`
   - Push history: `push_event(socket, "history", %{data: Base.encode64(history)})`
   - Assign `:target`, `:pane_stream_pid`, `:monitor_ref`
4. On error:
   - `:pane_not_found` → show error UI
   - `:max_pane_streams` → show error UI

**`handle_info` callbacks**:
- `{:pane_output, _target, data}` → `push_event(socket, "output", %{data: Base.encode64(data)})`
- `{:pane_dead, _target}` → `push_event(socket, "pane_dead", %{})`
- `{:pane_superseded, _old_target, new_target}` → unsubscribe, parse new_target, `push_navigate` to new URL
- `{:pane_resized, cols, rows}` → `push_event(socket, "resized", %{cols: cols, rows: rows})`
- `{:pane_reconnected, _target, buffer}` → `push_event(socket, "reconnected", %{data: Base.encode64(buffer)})`
- `{:DOWN, ref, :process, _pid, _reason}` → PaneStream crashed. Demonitor old ref, re-subscribe, push fresh history via "reconnected" event, monitor new PID. If pane gone, show dead UI.

**`handle_event` callbacks**:
- `"key_input"` → `Base.decode64/1` (log + ignore invalid), validate size ≤ 128KB, `PaneStream.send_keys(target, bytes)`
- `"resize"` → validate cols/rows bounds, forward to PaneStream which calls `tmux resize-pane` and broadcasts

**`terminate/2`**:
- Call `PaneStream.unsubscribe(target)`

### 5.4 Terminal View Template

**`lib/remote_code_agents_web/live/terminal_live.html.heex`**:

```heex
<div class="flex flex-col h-dvh bg-black">
  <%!-- Header bar --%>
  <header class="flex items-center justify-between px-4 py-2 bg-gray-900 border-b border-gray-700">
    <.link navigate={~p"/"} class="text-gray-400 hover:text-white">
      ← Back
    </.link>
    <span class="text-gray-300 text-sm font-mono"><%= @target %></span>
    <.link navigate={~p"/settings"} class="text-gray-400 hover:text-white">
      ⚙
    </.link>
  </header>

  <%!-- Terminal container --%>
  <div id="terminal" phx-hook="TerminalHook" phx-update="ignore" class="flex-1 min-h-0"></div>

  <%!-- Pane dead overlay --%>
  <div :if={@pane_dead} class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
    <div class="text-center text-white">
      <p class="text-xl mb-4">Session ended</p>
      <.link navigate={~p"/"} class="px-4 py-2 bg-blue-600 rounded">Back to Sessions</.link>
    </div>
  </div>
</div>
```

### 5.5 Route Configuration

Update router:
```elixir
live "/terminal/:target", TerminalLive
```

Note: The target param uses `:` and `.` separators (e.g., `mysession:0.1`). Phoenix routes handle this fine — the entire path segment is captured as the `:target` param.

### 5.6 Resize Handling

- **Strategy: last writer wins.** Any desktop viewer can send resize events; the most recent one takes effect. This is simple and matches tmux's own behavior (the last `resize-pane` call wins).
- Client sends resize after `FitAddon.fit()` and on window resize (debounced 300ms)
- Server validates: cols 1-500, rows 1-200
- Server calls `tmux resize-pane -t {pane_id} -x {cols} -y {rows}` via PaneStream
- PaneStream broadcasts `{:pane_resized, cols, rows}` to all viewers
- Other viewers receive and resize their xterm.js instances
- Throttle: server ignores resize events within 500ms of last resize for same pane
- Mobile viewers are passive resizers (Phase 9) — they do not send resize events

### 5.7 Mobile Layout

- Terminal fills `100dvh` (dynamic viewport height)
- Header auto-hides after 3s of inactivity, tap top edge to reveal
- Terminal container uses `flex-1 min-h-0` to fill remaining space

### 5.8 Tests

**`test/remote_code_agents_web/live/terminal_live_test.exs`**:
- Mount with valid target, verify history push
- Mount with invalid target, verify error UI
- Test key_input event handling (valid base64, invalid base64)
- Test pane_dead notification
- Test PaneStream crash recovery (`:DOWN` handling)

## Files Created/Modified
```
assets/js/hooks/terminal_hook.js
assets/js/app.js
lib/remote_code_agents_web/live/terminal_live.ex
lib/remote_code_agents_web/live/terminal_live.html.heex
lib/remote_code_agents_web/router.ex (update routes)
test/remote_code_agents_web/live/terminal_live_test.exs
```

## Exit Criteria
- Click a pane in session list → full-viewport terminal opens
- Terminal shows scrollback history on attach
- Typing in browser reaches the tmux pane (visible output)
- Terminal output streams in real-time
- Ctrl+C, arrow keys, escape sequences work correctly
- Pane death shows overlay with "Back to Sessions" link
- Resize works: browser resize triggers tmux pane resize
- Copy/paste works (desktop: Ctrl+Shift+V; selection auto-copies)
- Multiple browser tabs on same pane share the stream
- PaneStream crash → terminal recovers transparently
