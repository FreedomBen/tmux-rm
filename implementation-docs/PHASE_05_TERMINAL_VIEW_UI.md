# Phase 5: Terminal View Web UI

## Goal
Implement `TerminalLive` and the `TerminalHook` JavaScript module. After this phase, users can click a pane in the session list and get a full-viewport interactive terminal in the browser with real-time streaming output and keyboard input.

## Dependencies
- Phase 3 complete (PaneStream)
- Phase 4 complete (session list with navigation)
- xterm.js npm packages installed (Phase 1)

## Steps

### 5.1 TerminalHook (JavaScript)

**`server/assets/js/hooks/terminal_hook.js`**:

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
5. **Open companion Channel** for binary terminal I/O (see 5.9 below):
   ```javascript
   const target = this.el.dataset.target;
   // Convert "session:window.pane" to Channel topic "terminal:session:window:pane"
   const topic = "terminal:" + target.replace(".", ":").replace(/^([^:]+):/, "$1:");
   this.channel = window.userSocket.channel(topic, {});
   this.channel.join()
     .receive("ok", (reply) => {
       // Write history (base64 in join reply)
       const historyBytes = Uint8Array.from(atob(reply.history), c => c.charCodeAt(0));
       term.write(historyBytes);
     })
     .receive("error", (reason) => { /* show error UI */ });
   ```
6. Send initial resize: `this.pushEvent("resize", {cols: term.cols, rows: term.rows})`

**`onData` handler** (keyboard input):
- Buffer keystrokes in a local array
- Flush every 16ms (via `requestAnimationFrame`) or when buffer exceeds 64 bytes
- On flush: concatenate bytes, encode to UTF-8 via `TextEncoder`, send as binary frame via Channel: `this.channel.push("input", new ArrayBuffer(bytes))`

**`onResize` handler**:
- Debounce 300ms
- Send `this.pushEvent("resize", {cols, rows})`

**Channel event handlers** (binary terminal data via companion Channel — no base64 overhead):
- `this.channel.on("output", (msg) => { ... })` — receive binary payload, `term.write(new Uint8Array(msg))`
- History: received in Channel join reply as base64 (JSON text frame exception), decoded and written to terminal on join success
- `this.channel.on("reconnected", (msg) => { ... })` — `term.reset()`, write binary payload
- `this.channel.on("pane_dead", () => { ... })` — display "Session ended" overlay with link back to session list

**LiveView event handlers** (control/UI events only — no terminal data):
- `this.handleEvent("pane_superseded", ({new_target}) => { ... })` — LiveView handles navigation to new URL
- `this.handleEvent("pane_resized", ({cols, rows}) => { ... })` — resize xterm.js to match

**Clipboard**:
- Copy: user selects text in terminal, uses Ctrl+Shift+C (or right-click → Copy) to copy. No auto-copy on selection (browsers gate clipboard writes behind user gestures in secure contexts, and auto-copy is disruptive).
- Paste: intercept Ctrl+Shift+V → `navigator.clipboard.readText()` → send as `"key_input"` event
- Fallback to `document.execCommand` for older browsers

**LiveView reconnection handling**:
- When LiveView reconnects (e.g., after network drop or server restart), `mounted()` fires again on the same DOM element
- On reconnect: check if xterm.js instance already exists on `this.el`; if so, call `term.reset()` before writing new history
- The server re-runs `mount/3` on reconnect, which re-subscribes to PaneStream and pushes fresh history via the `"history"` event
- This ensures the terminal state is reconciled: server sends full ring buffer contents, client resets and replays

**`destroyed()`**:
- Leave Channel: `this.channel.leave()`
- Dispose xterm.js instance
- Cancel any pending timers

### 5.2 Register Hook and UserSocket in app.js

**`server/assets/js/app.js`**:
```javascript
import { Socket } from "phoenix";
import { TerminalHook } from "./hooks/terminal_hook";

// Companion Channel socket for binary terminal I/O
// Auth token is embedded in the page by LiveView (see 5.9)
const userToken = document.querySelector("meta[name='channel-token']")?.content;
window.userSocket = new Socket("/socket", { params: { token: userToken } });
window.userSocket.connect();

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { TerminalHook },
  // ...
});
```

### 5.3 TerminalLive (Server)

**`server/lib/tmux_rm_web/live/terminal_live.ex`**:

**Architecture**: TerminalLive handles UI/control concerns only. Terminal data (output/input) flows through the companion TerminalChannel (Phase 11) opened by the JS hook. LiveView does NOT subscribe to PaneStream for output — the Channel handles that. This eliminates base64 overhead entirely for terminal data.

**`mount/3`**:
1. Parse target from URL params: `"#{session}:#{window}.#{pane}"`
2. Verify pane exists via `TmuxManager.session_exists?/1` (lightweight check — full PaneStream subscription happens via Channel)
3. Generate a short-lived Channel token: `Phoenix.Token.sign(socket, "channel", %{})` — embed in socket assigns for the template to render as a `<meta>` tag
4. Assign `:target`, `:channel_token`, `:pane_dead` (false)

**`handle_info` callbacks** (subscribed to PubSub `"pane:#{target}"` for control events only):
- `{:pane_dead, _target}` → assign `:pane_dead` to true (shows overlay in template)
- `{:pane_superseded, _old_target, new_target}` → `push_navigate` to new URL
- `{:pane_resized, cols, rows}` → `push_event(socket, "pane_resized", %{cols: cols, rows: rows})`

**`handle_event` callbacks**:
- `"resize"` → validate cols/rows bounds, forward to PaneStream which calls `tmux resize-pane` and broadcasts

**`terminate/2`**:
- No PaneStream unsubscribe needed (Channel handles its own lifecycle)

**Note**: Input (`key_input`) and output are handled entirely by the companion Channel — they never touch LiveView. This means LiveView's JSON serialization overhead is avoided for all terminal data.

### 5.4 Terminal View Template

**`server/lib/tmux_rm_web/live/terminal_live.html.heex`**:

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

### 5.9 Hybrid LiveView + Channel Architecture

**Why**: LiveView serializes all data as JSON. Terminal output is binary — base64 encoding it adds 33% overhead on every frame. Phoenix Channels natively support binary WebSocket frames with zero encoding overhead.

**How it works**:
1. User navigates to `/terminal/:target` — LiveView mounts, renders the page and a `<meta name="channel-token">` tag containing a signed Phoenix token
2. `TerminalHook.mounted()` reads the token from the meta tag, connects to `UserSocket`, and joins `TerminalChannel` with the pane's topic
3. TerminalChannel subscribes to PaneStream, sends history in the join reply, and pushes binary output frames
4. Input from the keyboard flows through the Channel as binary frames — never touches LiveView
5. LiveView handles only control/UI: resize events, pane death overlay, navigation (supersede)

**Data flow**:
```
Keyboard → TerminalHook → Channel (binary) → PaneStream → tmux
tmux → PaneStream → Channel (binary) → TerminalHook → xterm.js
resize → TerminalHook → LiveView (JSON) → PaneStream → tmux
pane_dead → PaneStream → LiveView (JSON) → TerminalHook → overlay
```

**Template meta tag** (in `server/lib/tmux_rm_web/live/terminal_live.html.heex`):
```heex
<meta name="channel-token" content={@channel_token} />
```

**Dependency resolution**: Phase 5 builds the core `TerminalChannel` (join, output push, input handler, PaneStream subscription). This is straightforward server-side code — just a Channel module. Phase 11 later adds `SessionChannel` and documents the native client protocol, but does NOT re-create TerminalChannel. Phase 5 owns TerminalChannel; Phase 11 extends it if needed.

**UserSocket**: Phase 5 creates `server/lib/tmux_rm_web/channels/user_socket.ex` as a stub (no auth verification — pass-through `connect/3`). Phase 6 adds token verification to `connect/3`. Phase 11 adds the `channel "sessions", SessionChannel` registration. The initial Phase 5 UserSocket:
```elixir
defmodule TmuxRmWeb.UserSocket do
  use Phoenix.Socket

  channel "terminal:*", TmuxRmWeb.TerminalChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
```

### 5.5 Route Configuration

Update router:
```elixir
live "/terminal/:target", TerminalLive
```

Note: The target param uses `:` and `.` separators (e.g., `mysession:0.1`). Phoenix routes handle this fine — the entire path segment is captured as the `:target` param.

**URL scheme relationship with Phase 12**: This single-pane view (`/terminal/:target`) provides a full-viewport terminal for one pane. Phase 12 adds a multi-pane view (`/sessions/:session/windows/:window`) showing all panes in a window. Both views coexist:
- Session list (Phase 4) links to individual panes via `/terminal/:target` for the single-pane experience
- Phase 12 adds an additional "Window view" link to `/sessions/:session/windows/:window`
- The multi-pane view has a "Focus" button per pane that navigates to `/terminal/:target`

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

**`server/test/tmux_rm_web/live/terminal_live_test.exs`**:
- Mount with valid target, verify history push
- Mount with invalid target, verify error UI
- Test key_input event handling (valid base64, invalid base64)
- Test pane_dead notification
- Test PaneStream crash recovery (`:DOWN` handling)

## Files Created/Modified
```
server/assets/js/hooks/terminal_hook.js
server/assets/js/app.js (update — add UserSocket connection)
server/lib/tmux_rm_web/live/terminal_live.ex
server/lib/tmux_rm_web/live/terminal_live.html.heex
server/lib/tmux_rm_web/channels/terminal_channel.ex (core TerminalChannel — extended in Phase 11)
server/lib/tmux_rm_web/channels/user_socket.ex (update — register terminal:* channel)
server/lib/tmux_rm_web/router.ex (update routes)
server/test/tmux_rm_web/live/terminal_live_test.exs
server/test/tmux_rm_web/channels/terminal_channel_test.exs
```

## Exit Criteria
- Click a pane in session list → full-viewport terminal opens
- Terminal shows scrollback history on attach (via Channel join reply)
- Typing in browser reaches the tmux pane (via Channel binary frames — no base64)
- Terminal output streams in real-time (via Channel binary frames — no base64)
- Ctrl+C, arrow keys, escape sequences work correctly
- Pane death shows overlay with "Back to Sessions" link
- Resize works: browser resize triggers tmux pane resize (via LiveView event)
- Copy/paste works (desktop: Ctrl+Shift+V; selection auto-copies)
- Multiple browser tabs on same pane share the PaneStream (each has its own Channel)
- PaneStream crash → Channel receives `:DOWN`, re-subscribes, pushes fresh history
- LiveView handles only control/UI — zero terminal data passes through LiveView

## Checklist
- [x] 5.1 TerminalHook (JavaScript)
- [x] 5.2 Register Hook and UserSocket in app.js
- [x] 5.3 TerminalLive (Server)
- [x] 5.4 Terminal View Template
- [x] 5.9 Hybrid LiveView + Channel Architecture
- [x] 5.5 Route Configuration
- [x] 5.6 Resize Handling
- [x] 5.7 Mobile Layout
- [x] 5.8 Tests
