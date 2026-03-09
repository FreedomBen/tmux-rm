# Remote Code Agents - Application Design

## Overview

A web application built with Elixir, Phoenix, and LiveView that runs on a host computer and provides a browser-based interface to interact with tmux sessions. This enables remote access to terminal sessions — particularly useful for monitoring and interacting with long-running processes, code agents, or development environments.

The application must work well over high-latency and low-bandwidth connections, and be fully usable on mobile browsers. A native Android app is a future target, so the architecture should cleanly separate the transport/API layer from the web UI.

## Goals

- Attach to existing tmux sessions from a web browser
- Create new tmux sessions from the UI
- Stream terminal output in real-time via LiveView WebSocket
- Send keyboard input back to the tmux pane
- Support multiple simultaneous viewers on the same pane (shared stream)
- Capture scrollback history when attaching to a pane
- Clipboard integration (copy/paste)
- Mobile-friendly UI — usable on phone browsers
- Minimal setup — run alongside existing tmux workflows
- Optimized for high-latency / low-bandwidth connections

## Architecture

### High-Level Components

```
Browser / Android App
    |
    | WebSocket
    |
    |-- LiveView (web UI — terminal I/O via push_event/handle_event)
    |-- Phoenix Channel (raw terminal protocol — for native apps only)
    |
Phoenix Application
    |
    |-- TmuxManager (GenServer)
    |       Discovers sessions, creates new sessions
    |
    |-- PaneStream (GenServer, one per pane — shared across viewers)
    |       Registered via Registry as {:pane, "session:window.pane"}
    |       Streams output via `tmux pipe-pane` + FIFO
    |       Sends keystrokes via `tmux send-keys`
    |       Manages viewer reference counting
    |       Detects pane death (Port EOF) and notifies viewers
    |
    |-- PaneStreamSupervisor (DynamicSupervisor)
    |       Lifecycle management for PaneStream processes
    |
    |-- Registry (RemoteCodeAgents.PaneRegistry)
    |       Process lookup for PaneStreams by target key
    |
tmux server (host)
    |
    |-- pipe-pane → FIFO/pipe per pane (output streaming)
    |-- capture-pane (initial scrollback snapshot)
    |-- send-keys (input)
```

### Web vs Native Client Strategy

The web and native clients use different transport mechanisms but share the same backend (PaneStream + PubSub):

1. **Web (LiveView)**: Terminal I/O flows through the existing LiveView WebSocket via `push_event` (server→client) and `handle_event` (client→server). The `TerminalHook` on the client translates between LiveView events and xterm.js. This avoids opening a second WebSocket connection from the browser.

2. **Native Android (Phoenix Channel)**: Connects directly to a `TerminalChannel` via a dedicated WebSocket. Speaks a simple binary/JSON protocol. This is **future** — the Channel is not needed for the web client.

3. **Shared backend**: Both LiveView processes and Channel processes subscribe to the same PubSub topics and call the same PaneStream API. No terminal logic is duplicated.

```
Web browser:
  xterm.js ↔ TerminalHook ↔ LiveView push_event/handle_event ↔ PaneStream

Android app (future):
  TerminalView ↔ TerminalChannel ↔ PaneStream
```

### Key Modules

#### `RemoteCodeAgents.TmuxManager`
- **Responsibility**: Discover, list, and create tmux sessions
- **Interface**:
  - `list_sessions/0` — returns `[%Session{name, windows, created, attached?}]`
  - `list_panes/1` — returns panes for a given session/window
  - `create_session/1` — creates a new tmux session with given name, returns session info. Broadcasts `{:sessions_changed}` on PubSub topic `"sessions"` on success.
  - `kill_session/1` — terminates a session. Broadcasts `{:sessions_changed}` on PubSub topic `"sessions"` on success.
  - `session_exists?/1` — check if a session is still alive
- **Implementation**: Shells out to `tmux list-sessions`, `tmux list-windows`, `tmux list-panes`, `tmux new-session` with format strings; parses output
- **Session name validation**: Names must match `^[a-zA-Z0-9_-]+$` (alphanumeric, hyphens, underscores). Reject anything else at creation time. This prevents conflicts with the tmux target format `session:window.pane` where colons and periods are delimiters.
- **Not a GenServer**: Stateless module with functions that shell out. No need to cache session state since the source of truth is tmux itself. Can be promoted to a GenServer later if we need to rate-limit tmux CLI calls.

#### `RemoteCodeAgents.PaneStream`
- **Responsibility**: Bidirectional bridge between a tmux pane and one or more viewers
- **Registration**: Via `Registry` with key `{:pane, target}` where `target` is the `"session:window.pane"` string. Lookup via `Registry.lookup(RemoteCodeAgents.PaneRegistry, {:pane, target})`.
- **State**:
  - `target` — the `session:window.pane` identifier
  - `pipe_port` — Elixir Port running `cat` on the FIFO
  - `viewers` — `MapSet` of subscriber PIDs (monitored)
  - `buffer` — ring buffer (`RemoteCodeAgents.RingBuffer`) of all output (scrollback + streaming). Sized dynamically based on the pane's tmux `history-limit` and width (see Buffer Sizing below). All viewers — first or late — receive the same history from this buffer. `RingBuffer.read/1` returns a single contiguous binary by concatenating the two halves of the circular buffer internally.
  - `status` — `:streaming | :dead`
  - `grace_timer_ref` — reference from `Process.send_after/3` for the grace period timer, or `nil`. Used by `Process.cancel_timer/1` when a new viewer subscribes during the grace period.
- **Interface**:
  - `start_link/1` — starts streaming for a target pane
  - `subscribe/1` — called by a viewer process. Uses `self()` to identify the caller. Checks Registry for an existing PaneStream; if not found, starts one under DynamicSupervisor. Monitors the caller PID, subscribes the caller to the PubSub topic `"pane:#{target}"`, and returns `{:ok, history}` where `history` is the current ring buffer contents (a single contiguous binary from `RingBuffer.read/1`). PubSub subscription happens inside the GenServer call before history is returned, guaranteeing no messages are lost between receiving history and streaming. Returns `{:error, :pane_not_found}` if the tmux pane does not exist (detected during startup when `pipe-pane` fails).
  - `unsubscribe/1` — called by a viewer process. Uses `self()` to identify the caller. Removes the caller from the viewer set. If no viewers remain, starts the grace period timer.
  - `send_keys/2` — sends input (as a binary) to the pane via `tmux send-keys -H`. Each byte of the binary is converted to its two-character hex representation. If status is `:dead`, skips the call and returns `{:error, :pane_dead}`. If the `send-keys` command fails (e.g., pane died between checks), logs a warning and returns `:ok` — pane death notification will follow shortly via the Port EOF flow.
- **Lifecycle**:
  - Monitors all viewer PIDs — auto-unsubscribes on viewer crash/disconnect
  - On last viewer unsubscribe: starts a configurable grace period timer (default 5s) via `Process.send_after(self(), :grace_period_expired, ...)`. If a new viewer subscribes within the grace period, cancel the timer via `Process.cancel_timer/1`. When the `:grace_period_expired` message arrives in `handle_info`, re-check `MapSet.size(viewers) == 0` before proceeding with shutdown — this eliminates the race between a late subscribe and the timer firing.
  - On Port exit (any status): set status to `:dead`, broadcast `{:pane_dead, target}` to all viewers, clean up FIFO, shut down after viewers acknowledge/disconnect. Log at `info` level for exit status 0 (normal pane death); log at `warning` level for non-zero (e.g., permission error, `cat` not found).

#### `RemoteCodeAgents.Tmux.CommandRunner`
- **Responsibility**: Execute tmux CLI commands and return parsed output
- **Interface**:
  - `run/1` — takes a list of argument strings (e.g., `["list-sessions", "-F", "#{session_name}"]`), prepends the tmux binary path, executes via `System.cmd/3`. Returns `{:ok, output}` or `{:error, reason}`.
  - `run!/1` — same but raises on error.
- **Rationale**: Single point of contact with the tmux CLI. Makes it easy to mock in tests and add logging/rate-limiting later.
- **Implementation**: Uses `System.cmd/3` with stderr capture. Validates that `tmux` is available on startup.
- **Minimum tmux version**: 2.6+ required (`send-keys -H` was added in 2.6). `CommandRunner` should check the tmux version on first use (via `tmux -V`) and log an error if below 2.6.

### tmux pipe-pane Strategy

**Why pipe-pane over capture-pane polling:**
- `capture-pane` polling at 100ms means up to 100ms latency per frame, wastes CPU diffing unchanged screens, and scales poorly with many panes
- `pipe-pane` gives true streaming — output arrives as soon as tmux processes it, with zero polling overhead
- Critical for high-latency connections: every millisecond of unnecessary server-side delay compounds with network latency

**Implementation — startup sequence:**

```
PaneStream startup (order matters):
  1. Create FIFO directory if needed: mkdir -p {fifo_dir}
  2. Create named pipe: mkfifo {fifo_dir}/pane-{sanitized_target}.fifo
  3. Start Elixir Port: open_port({:spawn, "cat {fifo_path}"}, [:binary, :stream, :exit_status])
     — `cat` blocks on FIFO open until a writer connects, which is fine
       because it runs in a separate OS process and won't block the GenServer
  4. Attach pipe: tmux pipe-pane -t {target} -o 'cat >> {fifo_path}'
     — `-o` flag captures output only (the stdout side of the pty), preventing
       the input side from being captured and doubled
     — This opens the write end of the FIFO, unblocking the `cat` reader
  5. Query buffer size: determine ring buffer capacity (see Buffer Sizing below)
  6. Capture initial scrollback: tmux capture-pane -p -e -S - -t {target}
     — `-S -` captures all available history; the ring buffer's size limit is the real cap
     — Done AFTER pipe-pane attach so no output is lost between steps
     — Any output generated between steps 4 and 6 will appear in both
       the pipe stream and the scrollback capture (minor duplication, but
       xterm.js handles redrawn content gracefully)
  7. Write scrollback into ring buffer as initial content
     — From this point on, the ring buffer is the single source of history
     — Streaming output from the pipe appends to the same buffer
     — Old content naturally rolls off as the buffer fills
```

**Startup sequence rationale**: The key insight is that `cat` on a FIFO blocks at the OS level until a writer opens the pipe, but since it's a Port (separate OS process), it doesn't block the Elixir GenServer. The GenServer can proceed to call `pipe-pane` which opens the write end, unblocking `cat`. This avoids the FIFO deadlock without needing `O_NONBLOCK` or `O_RDWR` hacks.

Scrollback is captured *after* pipe-pane is attached. This means there's a brief window where output appears in both the pipe stream and the scrollback capture. This is acceptable — xterm.js re-rendering overlapping content is invisible to the user, and it's far better than the alternative (capturing scrollback first and missing output between capture and pipe-pane attach).

The captured scrollback is written into the ring buffer as its initial content, making the ring buffer the single source of history for all viewers. As new output streams in, old scrollback naturally rolls off the end of the buffer. This eliminates the gap/overlap problem for late-joining viewers — every subscriber receives one contiguous block of history from the ring buffer.

**Shutdown sequence:**

```
PaneStream shutdown:
  1. Detach pipe: tmux pipe-pane -t {target}   (no -o flag = detach)
  2. Close the Port (sends SIGTERM to cat, which closes the FIFO read end)
  3. Remove the FIFO: File.rm({fifo_path})
```

**Application startup cleanup**: In `Application.start/2`, before the supervision tree starts, the FIFO directory is cleared (`File.rm_rf(fifo_dir)` then `File.mkdir_p(fifo_dir)`). This removes any stale FIFOs left behind by a previous crash or hard kill of the entire application.

**PaneStream crash recovery**: If a single PaneStream crashes, the supervisor restarts it. The `init/1` callback must:
  1. Check for and remove stale FIFO from previous instance
  2. Detach any existing pipe-pane on the target (`tmux pipe-pane -t {target}`)
  3. Re-run the normal startup sequence

**FIFO naming**: Target strings like `mysession:0.1` are sanitized for filesystem use by replacing `:` and `.` with `-`, giving FIFO names like `pane-mysession-0-1.fifo`.

### Buffer Sizing

The ring buffer is the single source of history for all viewers. Its size is computed dynamically per pane at PaneStream startup:

1. Query the pane's effective `history-limit`: `tmux show-option -wv -t {target} history-limit` (falls back to `tmux show-option -gv history-limit` for the global default)
2. Query the pane width: `tmux list-panes -t {target} -F '#{pane_width}'`
3. Compute: `history_limit × pane_width` bytes (one byte per cell is a conservative estimate — ANSI escape sequences add overhead but most lines aren't full-width)
4. Clamp the result between `ring_buffer_min_size` (default 256KB) and `ring_buffer_max_size` (default 4MB)
5. If either tmux query fails, use `ring_buffer_default_size` (default 1MB)

**Examples**:
- Default tmux (2000 lines × 120 cols) = 240KB → clamped to 256KB (floor)
- Heavy user (50000 lines × 200 cols) = 10MB → clamped to 4MB (ceiling)
- Typical dev (10000 lines × 120 cols) = 1.2MB → used as-is

This ensures the buffer automatically scales to match what tmux is retaining, without requiring manual configuration. The initial scrollback capture is written into this buffer, and streaming output appends to it — old content naturally rolls off as the buffer fills.

### Input Handling (send-keys)

**Problem**: `tmux send-keys -l` (literal mode) sends text literally but does **not** handle control characters. xterm.js `onData` emits raw terminal data including escape sequences (`\x03` for Ctrl+C, `\x1b[A` for arrow up, etc.). These must reach tmux correctly.

**Solution**: Use `tmux send-keys -H` (hex mode) for all input. The full encoding pipeline:

1. **Client (JS)**: xterm.js `onData` emits a JavaScript string (UTF-16). Encode to UTF-8 bytes via `new TextEncoder().encode(data)`, then base64-encode the result. Send via `pushEvent("key_input", {data: base64String})`.
2. **Server (Elixir)**: `Base.decode64!/1` recovers the raw UTF-8 bytes. Convert each byte to its two-character hex representation. Pass to `tmux send-keys -H`.

This mirrors the output path (server base64-encodes, client decodes) for symmetry.

```
Example: User types "hi" then Ctrl+C
  xterm.js onData emits: "hi\x03" (JS string)
  TextEncoder produces: <<0x68, 0x69, 0x03>> (UTF-8 bytes)
  Base64 encoded: "aGkD"
  Sent to server as: %{"data" => "aGkD"}
  Server decodes base64: <<0x68, 0x69, 0x03>>
  PaneStream calls: tmux send-keys -H -t {target} 68 69 03
```

**Why base64 for transport**: LiveView events are JSON-serialized. While raw control characters (`\x03`) are valid in JSON strings, base64 is more explicit, avoids edge cases with binary-unsafe intermediaries, and is symmetric with the output path.

**Why hex mode for tmux**: Simpler than branching between `-l` for printable chars and raw mode for control chars. No escaping edge cases. Works uniformly for all input including Unicode (UTF-8 bytes as hex).

**Performance**: For typical interactive use, `send-keys -H` with a handful of hex bytes per keystroke is negligible overhead. For bulk paste operations, we batch into a single `send-keys -H` call with all bytes.

### LiveView Pages

#### `RemoteCodeAgentsWeb.SessionListLive`
- Route: `/`
- Lists all active tmux sessions with their windows and panes
- "New Session" button/form — creates a new tmux session (name input with validation, optional starting command)
- **Session list updates** use a hybrid approach:
  - **Instant**: Subscribes to PubSub topic `"sessions"` on mount. `TmuxManager.create_session/1` and `kill_session/1` broadcast `{:sessions_changed}` on this topic after mutating state, so the session list updates immediately for app-driven changes.
  - **Polling fallback**: `Process.send_after(self(), :refresh_sessions, 3_000)` in `handle_info` catches external changes (sessions created/killed from the terminal). This is a lightweight local call (`tmux list-sessions` reads in-memory state).
- Click a pane to navigate to the terminal view via `push_navigate`
- Shows pane dimensions and running command (from `tmux list-panes -F` format)
- Mobile layout: full-width card list, large touch targets
- Empty state: friendly message when no tmux sessions exist, with prominent "Create Session" CTA

#### `RemoteCodeAgentsWeb.TerminalLive`
- Route: `/sessions/:session/:window/:pane`
- Full-viewport xterm.js terminal
- **LiveView Hook (`TerminalHook`)**:
  - `mounted()`: Creates xterm.js `Terminal` + `FitAddon`, opens terminal in container div, calls `FitAddon.fit()`, sends initial `resize` event to server
  - `onData`: xterm.js keyboard input → UTF-8 encode via `TextEncoder` → base64 encode → `this.pushEvent("key_input", {data: base64String})`
  - `onResize`: debounced (300ms) → `this.pushEvent("resize", {cols, rows})`
  - Server pushes `"output"` → `term.write(data)`
  - Server pushes `"history"` → `term.write(data)` (before streaming begins)
  - Server pushes `"pane_dead"` → display overlay message "Session ended", offer link back to session list
  - Clipboard: `onSelectionChange` → auto-copy to clipboard; paste handler intercepts Ctrl+Shift+V / toolbar button
  - `destroyed()`: Clean up xterm.js instance
- **Server side** (`mount/3`):
  - Constructs target from URL params: `"#{session}:#{window}.#{pane}"` (where session, window, pane are from the route `/sessions/:session/:window/:pane` — window and pane are integer indices)
  - Calls `PaneStream.subscribe(target)` — gets `{:ok, history}` (PubSub subscription is handled internally by `subscribe/1`, so no messages are lost between receiving history and streaming) or `{:error, :pane_not_found}` (show error UI)
  - Pushes history to client via `push_event(socket, "history", %{data: ...})`
  - `handle_info({:pane_output, data})` → `push_event(socket, "output", %{data: data})`
  - `handle_info({:pane_dead, _target})` → `push_event(socket, "pane_dead", %{})`
  - `handle_event("key_input", %{"data" => b64})` → `Base.decode64/1` with error handling (invalid base64 is logged and ignored, not crashed on) → `PaneStream.send_keys(target, bytes)`
  - `handle_event("resize", %{"cols" => c, "rows" => r})` → resize handling (see Resize Conflicts below)
  - `terminate/2`: calls `PaneStream.unsubscribe(target)`
- Mobile: on-screen virtual keyboard toolbar (see Mobile UI section)
- Back button / navigation header to return to session list

### Phoenix Channel: `TerminalChannel` (Future)

For native Android client only. Not used by the web UI.

- Topic: `"terminal:{session}:{window}:{pane}"`
- **Client → Server events**:
  - `"input"` — `%{"data" => binary}` — keyboard input
  - `"resize"` — `%{"cols" => int, "rows" => int}`
- **Server → Client events**:
  - `"output"` — `%{"data" => binary}` — terminal output bytes
  - `"history"` — `%{"data" => binary}` — ring buffer contents on join
  - `"pane_dead"` — pane/session no longer exists
- **Join handler**: Calls `PaneStream.subscribe/1`, subscribes to PubSub, same as TerminalLive
- **Auth**: Token-based authentication on join (future)

## Data Flow

### Terminal Output (tmux → browser)

1. tmux writes output → `pipe-pane` writes to FIFO
2. `cat` Port reads from FIFO → Elixir receives `{port, {:data, bytes}}`
3. PaneStream appends to ring buffer, broadcasts `{:pane_output, bytes}` via PubSub topic `"pane:#{target}"`
4. `TerminalLive` receives via `handle_info`, calls `push_event(socket, "output", %{data: Base.encode64(bytes)})`
5. `TerminalHook` decodes base64, calls `term.write(bytes)` on xterm.js instance

Note: Both input and output are base64-encoded for LiveView transport since LiveView events are JSON-serialized. Output: server encodes, client decodes. Input: client encodes (via `TextEncoder` + base64), server decodes. For the future Channel implementation, raw binary frames can be used instead.

### Initial Attach (history)

1. Viewer calls `PaneStream.subscribe(target)`
2. If PaneStream not running, starts it under DynamicSupervisor:
   a. Port starts `cat` on FIFO (blocks at OS level, not in GenServer)
   b. `pipe-pane` attached (unblocks `cat`)
   c. `capture-pane` captures scrollback, writes it into the ring buffer
3. PaneStream returns `{:ok, history}` — the current ring buffer contents
4. TerminalLive pushes history to client as `"history"` event
5. Client writes history to xterm.js, then streaming output follows

All viewers — first or late — follow the same path. The ring buffer always contains contiguous history (initial scrollback plus all subsequent streaming output, with old content rolling off as the buffer fills). No separate scrollback handling is needed.

### Keyboard Input (browser → tmux)

1. xterm.js `onData` callback fires with a JavaScript string
2. Hook encodes to UTF-8 via `TextEncoder`, then base64-encodes the bytes
3. Hook calls `this.pushEvent("key_input", {data: base64String})`
4. `TerminalLive.handle_event("key_input", %{"data" => b64})` decodes base64 via `Base.decode64!/1`, calls `PaneStream.send_keys(target, bytes)`
5. PaneStream converts bytes to hex, executes `tmux send-keys -H -t {target} {hex_bytes}`

### Pane Resize

1. xterm.js / FitAddon reports new dimensions after browser resize or orientation change
2. Hook debounces (300ms), sends `this.pushEvent("resize", {cols, rows})`
3. TerminalLive receives `handle_event("resize", ...)` — see Resize Conflict Resolution below

### Pane Death

1. tmux pane exits (process ends, user runs `exit`, session killed externally)
2. `pipe-pane` closes the write end of the FIFO
3. `cat` Port receives EOF, exits
4. PaneStream receives `{port, {:exit_status, status}}` in `handle_info`
5. PaneStream handles all exit statuses uniformly: sets status to `:dead`, broadcasts `{:pane_dead, target}` via PubSub, cleans up FIFO. Logs differ by status: `Logger.info` for status 0 (normal pane death), `Logger.warning` for non-zero (port error — e.g., permission denied, `cat` binary missing).
6. All TerminalLive viewers receive `handle_info({:pane_dead, _})`, push `"pane_dead"` event to client
7. Client shows "Session ended" overlay with link back to session list
8. PaneStream cleans up FIFO, terminates after a short delay

### Resize Conflict Resolution

Multiple viewers sharing a pane creates a conflict: resizing the tmux pane affects all viewers.

**Strategy: Last-writer-wins with dimension reporting**

- Any viewer can send a resize event
- Server applies `tmux resize-pane` with the requested dimensions
- Server broadcasts the new dimensions to ALL viewers via PubSub: `{:pane_resized, cols, rows}`
- Other viewers' xterm.js instances are resized to match via `FitAddon.fit()` or `term.resize(cols, rows)`
- On mobile, the terminal adapts to whatever size the pane currently is rather than requesting a resize. Mobile viewers are "passive resizers" — they read the current pane dimensions on connect and fit to them.

**Simplification**: Resizing is disabled — the pane keeps whatever dimensions it had when created. Viewers fit xterm.js to the existing pane size.

## Bandwidth Optimization

For low-bandwidth / high-latency connections:

1. **Streaming, not polling**: pipe-pane delivers only actual output — no wasted bandwidth on unchanged frames
2. **Base64 encoding overhead**: LiveView requires JSON-safe event payloads, so binary terminal data is base64-encoded (~33% overhead). Acceptable for terminal text. For the future Channel, raw binary frames eliminate this overhead.
3. **Compression**: Enable WebSocket per-message deflate compression in Phoenix endpoint config — terminal output (mostly text + ANSI codes) compresses very well
4. **Debounced resize**: Client debounces resize events (300ms) to avoid flooding during orientation changes
5. **Input batching**: Buffer rapid keystrokes client-side and send in batches (configurable, e.g. every 16ms) to reduce round-trip count
6. **Ring buffer cap**: History buffer sized dynamically per pane (see Buffer Sizing), clamped between 256KB and 4MB. Provides full scrollback context for all viewers without excessive memory or transfer

## Clipboard Integration

- **Copy**: xterm.js selection → `navigator.clipboard.writeText()` via the `onSelectionChange` callback. Automatically copies selected text. On mobile, long-press triggers native text selection which xterm.js supports.
- **Paste (desktop)**: Intercept `Ctrl+Shift+V` in the hook's keydown handler. Call `navigator.clipboard.readText()`, then send content as `"key_input"` event (which flows through `send_keys -H`).
- **Paste (mobile)**: "Paste" button in the virtual key toolbar calls `navigator.clipboard.readText()` → sends as `"key_input"` event.
- **Permission**: Clipboard API requires a secure context (HTTPS or localhost). Phase 1 (localhost) satisfies this. Phase 2 (remote access) requires HTTPS.
- **Fallback**: If Clipboard API is unavailable (older browsers, non-secure context), fall back to `document.execCommand('copy')`/`document.execCommand('paste')` with a textarea shim.

## Mobile UI Considerations

### Layout
- Session list: single-column card layout, large touch targets (min 48px height)
- Terminal view: full-viewport using `100dvh` (dynamic viewport height to account for mobile browser chrome)
- Collapsible header with session info and back button (auto-hides after 3s of inactivity, tap top edge to reveal)
- Bottom toolbar for special keys and actions

### Virtual Key Toolbar
A fixed bottom toolbar providing keys that don't exist on mobile keyboards:
```
[ Esc ] [ Tab ] [ Ctrl ] [ Alt ] [ ↑ ] [ ↓ ] [ ← ] [ → ] [ Paste ]
```
- `Ctrl` and `Alt` are sticky modifiers (tap to toggle, highlight when active)
- Swipe-up on toolbar reveals extended keys (F1-F12, PgUp/PgDn, Home/End)
- Toolbar auto-hides when the soft keyboard is open (to maximize terminal space), reappears on dismiss
- Each button emits the corresponding escape sequence / control code via `"key_input"` event

### Soft Keyboard Handling
- Tapping the terminal area opens the device soft keyboard
- Use a hidden `<input>` or `<textarea>` overlay to capture mobile keyboard input, forward to xterm.js
- `visualViewport` API used to detect soft keyboard open/close and adjust terminal + toolbar layout
- When soft keyboard is open: terminal shrinks to fit above keyboard, toolbar hides
- When soft keyboard closes: terminal expands to full viewport, toolbar reappears

### Touch Gestures
- Tap: focus terminal (opens soft keyboard)
- Long press: text selection (native xterm.js behavior)
- Two-finger pinch: zoom/font size adjustment (CSS transform on the terminal container)
- Swipe from left edge: back to session list (via browser back or custom gesture handler)

### Responsive Breakpoints
- `< 640px`: Mobile layout (single column, bottom toolbar, full-viewport terminal)
- `640px - 1024px`: Tablet (sidebar session list + terminal)
- `> 1024px`: Desktop (sidebar + terminal + status panel)

## Technology Choices

| Component          | Choice              | Rationale                                              |
|--------------------|---------------------|--------------------------------------------------------|
| Language           | Elixir 1.16+        | User preference; excellent for concurrent I/O          |
| Runtime            | OTP 26+             | Required by modern Phoenix/LiveView                    |
| Web framework      | Phoenix 1.7+        | Standard Elixir web framework                          |
| Real-time UI       | Phoenix LiveView 0.20+ | WebSocket-based, no separate API needed             |
| Terminal rendering | @xterm/xterm 5.x    | Battle-tested terminal emulator; handles ANSI, cursor  |
| xterm.js addons    | @xterm/addon-fit    | Required — auto-sizes terminal to container            |
|                    | @xterm/addon-web-links | Nice-to-have — makes URLs clickable in terminal     |
| CSS                | Tailwind CSS 3.x    | Ships with Phoenix 1.7+; utility-first, good for responsive |
| Terminal backend   | tmux pipe-pane      | True streaming, lower latency than polling              |
| Process registry   | Elixir Registry     | Built-in, lightweight process lookup by key            |
| Process management | DynamicSupervisor   | One child per active pane stream                       |
| Pub/Sub            | Phoenix.PubSub      | Built-in; connects PaneStreams to viewers               |
| User config (read) | yaml_elixir 2.11+   | YAML parser for quick actions + future settings        |
| User config (write)| ymlr 5.0+           | YAML encoder for writing config back to file           |
| Mobile terminal    | xterm.js + toolbar  | Works in mobile browsers; virtual key toolbar for special keys |
| Android (future)   | Phoenix Channel     | Direct WebSocket connection; native terminal renderer   |

## Project Structure

```
remote_code_agents/
  lib/
    remote_code_agents/
      application.ex               # Supervision tree
      tmux/
        command_runner.ex           # Thin wrapper around System.cmd for tmux CLI
        session.ex                  # Session struct
        pane.ex                     # Pane struct
      tmux_manager.ex               # Session/pane discovery + creation (stateless module)
      config.ex                     # YAML config loader + writer (~/.config/remote_code_agents/config.yaml)
      ring_buffer.ex                # Circular byte buffer with fixed capacity (new/1, append/2, read/1, size/1)
      pane_stream.ex                # Per-pane streaming GenServer (pipe-pane + FIFO)
      pane_stream_supervisor.ex     # DynamicSupervisor for PaneStreams
    remote_code_agents_web/
      channels/                     # Future
        terminal_channel.ex         # Raw terminal I/O channel (for native clients)
        user_socket.ex              # Socket configuration
      controllers/                  # REST API (for native clients)
        quick_action_controller.ex  # CRUD API for quick actions
      live/
        session_list_live.ex        # Session listing + creation page
        session_list_live.html.heex # Template
        terminal_live.ex            # Terminal view page
        terminal_live.html.heex     # Template
        settings_live.ex            # Settings panel (quick actions CRUD)
        settings_live.html.heex     # Settings template
      components/
        layouts.ex                  # App shell layout
        core_components.ex          # Shared UI components
  assets/
    js/
      hooks/
        terminal_hook.js            # xterm.js integration hook
      app.js
    css/
      app.css                       # Responsive styles, mobile layout, virtual toolbar
    package.json                    # xterm.js, @xterm/addon-fit dependencies
  config/
    config.exs
    dev.exs
    prod.exs
    runtime.exs
  test/
    remote_code_agents/
      tmux_manager_test.exs         # Unit tests with mocked CommandRunner
      pane_stream_test.exs          # Integration tests with real tmux
    remote_code_agents_web/
      live/
        session_list_live_test.exs
        terminal_live_test.exs
    support/
      tmux_helpers.ex               # Test helpers: create/destroy tmux sessions
    test_helper.exs
  mix.exs
```

## Supervision Tree

```
Application
  ├── RemoteCodeAgents.PaneRegistry (Registry)
  ├── RemoteCodeAgents.PaneStreamSupervisor (DynamicSupervisor)
  ├── Phoenix.PubSub (RemoteCodeAgents.PubSub)
  └── RemoteCodeAgentsWeb.Endpoint
```

- `PaneRegistry` starts first — PaneStreams need it for registration
- `PaneStreamSupervisor` starts next — ready to accept PaneStream children
- PubSub and Endpoint follow standard Phoenix ordering
- No TmuxManager in the tree — it's a stateless module, not a process

## Configuration

```elixir
# config/config.exs
config :remote_code_agents,
  # Grace period (ms) before shutting down a PaneStream with zero viewers
  pane_stream_grace_period: 5_000,
  # Ring buffer size bounds (bytes) — actual size is computed dynamically per pane
  # from tmux history-limit × pane width, clamped to these bounds
  ring_buffer_min_size: 262_144,    # 256 KB floor
  ring_buffer_max_size: 4_194_304,  # 4 MB ceiling
  ring_buffer_default_size: 1_048_576,  # 1 MB fallback if tmux query fails
  # Default terminal dimensions (used when creating new sessions)
  default_cols: 120,
  default_rows: 40,
  # FIFO directory for pipe-pane output
  fifo_dir: "/tmp/remote-code-agents",
  # Path to tmux binary (auto-detected if nil)
  tmux_path: nil

# config/dev.exs
config :remote_code_agents, RemoteCodeAgentsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  # Enable WebSocket compression
  websocket: [compress: true]

# config/test.exs
config :remote_code_agents,
  # Use shorter grace period in tests
  pane_stream_grace_period: 100,
  fifo_dir: "/tmp/remote-code-agents-test"
```

## Security Considerations

- **Authentication**: This application gives full terminal access. Must be protected:
  - Phase 1: Bind to `127.0.0.1` only (local access)
  - Phase 2: Add token-based auth for remote access (required for mobile use)
- **Input handling**: All input sent via `send-keys -H` (hex mode) — bytes are passed directly to tmux with no shell interpretation. The user is intentionally sending arbitrary commands to a shell — access control is the real security boundary.
- **Session name validation**: Enforced at `TmuxManager.create_session/1` — only `^[a-zA-Z0-9_-]+$` accepted. Prevents tmux target format injection.
- **HTTPS**: Required if exposed beyond localhost; configure via Phoenix endpoint or reverse proxy. Also required for Clipboard API access.
- **Channel auth**: `TerminalChannel` (future) must verify auth token on join to prevent unauthorized WebSocket connections from native apps
- **FIFO permissions**: Created with mode `0600` (owner read/write only) to prevent other users on the host from reading terminal output

## Testing Strategy

### Unit Tests
- **TmuxManager**: Mock `CommandRunner` to return canned tmux output. Test parsing of `list-sessions`, `list-panes` format strings. Test session name validation. Test error cases (tmux not running, session doesn't exist).
- **PaneStream**: Test state machine logic (subscribe/unsubscribe/grace period) with mocked tmux commands. Test ring buffer behavior (append, cap, read).

### Integration Tests
- **PaneStream + tmux**: Start a real tmux session in test setup, attach PaneStream, send keys, verify output arrives. Requires tmux installed in CI.
- **LiveView**: Use `Phoenix.LiveViewTest` — mount `TerminalLive`, simulate events, verify `push_event` calls. Mock PaneStream for isolation.
- **SessionListLive**: Mount, verify session listing renders. Test "New Session" form submission.

### Test Helpers (`test/support/tmux_helpers.ex`)
- `create_test_session/1` — creates a tmux session with a unique name, returns name
- `destroy_test_session/1` — kills the session
- `setup_tmux/1` — ExUnit setup callback that creates a session and registers cleanup via `on_exit`

### CI Requirements
- tmux must be installed in CI environment
- Tests tagged `@tag :tmux` for integration tests that need a real tmux server
- Unit tests (mocked) run without tmux

## Error Handling

### tmux Not Installed
- `CommandRunner` checks for tmux binary on first call (or application startup)
- If missing, log a clear error message and return `{:error, :tmux_not_found}` from all TmuxManager functions
- SessionListLive shows an error banner: "tmux is not installed. Please install tmux to use this application."

### tmux Server Not Running
- `tmux list-sessions` returns exit code 1 with "no server running" message
- TmuxManager returns `{:ok, []}` (empty session list) — not an error, just no sessions
- User can create a new session, which implicitly starts the tmux server

### Pane Died While Viewing
- See "Pane Death" data flow section above
- Client shows non-intrusive "Session ended" overlay with options: "Back to Sessions" or "Reconnect" (if the session was recreated)

### FIFO Errors
- FIFO directory doesn't exist → create it in PaneStream init
- FIFO already exists (stale from crash) → remove and recreate
- Permission denied → log error, return `{:error, :fifo_permission_denied}`

## Resolved Design Decisions

1. **Capture strategy → pipe-pane**: True streaming via `tmux pipe-pane` to a FIFO, read by a `cat` Port. Initial scrollback captured via `capture-pane` and written into the ring buffer. The startup sequence (Port first, then pipe-pane, then capture-pane, then seed buffer) avoids both FIFO deadlock and missed output.

2. **History → unified ring buffer**: Initial scrollback is written into the ring buffer at startup. All viewers — first or late — receive history from this single buffer. Buffer size is computed dynamically from the pane's tmux `history-limit` × width, clamped between 256KB and 4MB (default 1MB fallback). Old content rolls off naturally as new output streams in.

3. **Multiple viewers → Shared PaneStream**: One PaneStream per pane, shared across all viewers via PubSub. Reference-counted via monitored PIDs with a grace period on last-viewer-disconnect.

4. **Session creation → Yes**: The session list page always shows a "New Session" option alongside existing sessions. User provides a session name (validated: alphanumeric/hyphens/underscores only); optionally a starting command.

5. **Clipboard → Yes**: Copy via xterm.js selection + Clipboard API. Paste via toolbar button (mobile) or Ctrl+Shift+V (desktop). Requires secure context (localhost or HTTPS). Fallback to execCommand for older browsers.

6. **Web transport → LiveView push_event**: Terminal I/O on web flows through the existing LiveView WebSocket. No second WebSocket connection. Phoenix Channel is future, only for native Android client.

7. **Input encoding → send-keys -H (hex)**: All input bytes converted to hex and sent via `tmux send-keys -H`. Handles printable text, control characters, and escape sequences uniformly. No branching between literal and raw modes.

8. **FIFO blocking → cat Port**: The `cat` command runs as a Port (separate OS process), blocking on FIFO open without blocking the GenServer. `pipe-pane` opens the write end, unblocking `cat`. Simple and reliable.

9. **Process lookup → Elixir Registry**: PaneStreams registered in `RemoteCodeAgents.PaneRegistry` with key `{:pane, target}`. `subscribe/1` checks Registry for an existing PaneStream; if not found, starts one under DynamicSupervisor. This "get or start" logic lives inside `subscribe/1` — there is no separate public `get_or_start` function.

10. **Resize conflicts → disabled**: Panes keep their existing dimensions and viewers adapt. Future: last-writer-wins with dimension broadcast to all viewers; mobile viewers are passive (read-only resize).

11. **Session name validation → strict**: Only `^[a-zA-Z0-9_-]+$` allowed. Prevents tmux target format breakage from colons/periods in names.

## Scope

1. List tmux sessions and panes on the index page
2. Create new tmux sessions from the UI (with name validation)
3. Click a pane to open a full-viewport terminal view with xterm.js
4. Stream output from the pane using pipe-pane (with history on attach)
5. Send keyboard input from the browser to the pane (via send-keys -H)
6. Shared PaneStream with viewer ref counting and grace period
7. Clipboard copy/paste
8. Mobile-responsive layout with virtual key toolbar
9. Bind to localhost only (no auth needed)
10. Pane death detection and user notification
11. Error handling (tmux not installed, pane died, FIFO errors)
12. Resize disabled — viewers adapt to existing pane dimensions

## Storage Decision: No Database

This application is **fully stateless from a storage perspective**. No database is needed.

| Concern                | Where state lives                                      |
|------------------------|--------------------------------------------------------|
| Session/pane state     | tmux itself (source of truth)                          |
| Streaming state        | PaneStream GenServer memory (ephemeral)                |
| Viewer tracking        | PaneStream GenServer memory (ephemeral)                |
| Auth tokens            | Config file / environment variable (static)            |
| Quick actions          | YAML config file `~/.config/remote_code_agents/config.yaml` |
| User preferences       | Browser `localStorage` (client-side)                   |
| Layout preferences     | Browser `localStorage` (client-side)                   |

**Rationale**: tmux is the source of truth for all terminal state. Runtime coordination lives in GenServer memory and PubSub. Auth is single-user, handled by a static token. User preferences (font size, theme, layout) are per-device and belong in the browser. There is no data that requires durable server-side storage.

**Implications**:
- No Ecto dependency, no migrations, no database process to manage
- Application restarts are clean — PaneStreams re-attach to existing tmux sessions on demand
- Deployment is a single binary (Mix release) with zero infrastructure dependencies beyond tmux
- If multi-user support is ever needed (unlikely for this tool's use case), a database could be introduced then

---

## Feature Designs

### Authentication & Remote Access

**Goal**: Access terminal sessions from a phone or remote machine over the internet, securely.

#### Token-Based Authentication

- **Single static token**: Generated once, stored in config or environment variable. Suitable for a personal/single-user tool.
- **Token generation**: `mix rca.gen.token` Mix task generates a cryptographically random token, prints it, and writes to `~/.config/remote_code_agents/token`. Alternatively, set `RCA_AUTH_TOKEN` environment variable.
- **Token storage**: Read from `Application.get_env(:remote_code_agents, :auth_token)` at runtime. Loaded from env var in `runtime.exs`:
  ```elixir
  # config/runtime.exs
  config :remote_code_agents,
    auth_token: System.get_env("RCA_AUTH_TOKEN")
  ```
- **No token configured**: If `auth_token` is `nil`, auth is disabled (localhost-only mode). If the endpoint is bound to `0.0.0.0` and no token is set, log a warning on startup.

#### Auth Flow — Web

1. User navigates to the app. If no valid session cookie, redirect to `/login`.
2. `/login` page shows a single "Token" input field.
3. On submit, server verifies token via `Plug.Crypto.secure_compare/2` (constant-time comparison).
4. On success, set a signed session cookie (`Plug.Session` with `:cookie` store, signed with `secret_key_base`). Cookie expiry configurable (default 30 days).
5. All LiveView mounts check `on_mount` hook for valid session. Redirect to `/login` if missing.

#### Auth Flow — Phoenix Channel (Android)

1. Android app sends token as a param on socket connect: `socket("/socket", UserSocket, params: {"token" => "..."})`
2. `UserSocket.connect/3` verifies the token. Returns `{:ok, socket}` or `:error`.
3. On `:error`, the client receives a connection rejection and prompts for a new token.

#### Implementation Modules

- `RemoteCodeAgentsWeb.Plugs.RequireAuth` — Plug that checks session cookie, redirects to `/login`
- `RemoteCodeAgentsWeb.AuthLive` — LiveView for the login page
- `RemoteCodeAgentsWeb.AuthHook` — `on_mount` hook for LiveView auth checks

#### HTTPS

For remote access, HTTPS is required (both for security and Clipboard API).

**Options** (choose one at deployment time):
1. **Reverse proxy**: nginx/Caddy in front, handles TLS termination. App stays on HTTP internally. Simplest if the host already runs a reverse proxy.
2. **Phoenix direct TLS**: Configure `:https` in endpoint config with cert/key paths. Works with Let's Encrypt certs (certbot) or self-signed certs.
3. **Tailscale/WireGuard**: VPN-based access. No public exposure, no certs needed. App stays HTTP on the Tailscale interface. Easiest for personal use.

**Recommendation for personal use**: Tailscale. Zero configuration TLS (MagicDNS provides HTTPS via `tailscale cert`), no port forwarding, no public exposure. The app binds to the Tailscale interface IP instead of `127.0.0.1`.

```elixir
# config/runtime.exs — remote access example
if auth_token = System.get_env("RCA_AUTH_TOKEN") do
  config :remote_code_agents,
    auth_token: auth_token

  config :remote_code_agents, RemoteCodeAgentsWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: 4000]
end
```

### Phoenix Channel + Native Android Client

**Goal**: Android app connects directly to the server via WebSocket, renders terminal natively.

#### Channel Protocol

The `TerminalChannel` speaks a simple protocol over the Phoenix Channel WebSocket:

**Connection**: Client connects to `wss://host:port/socket/websocket` with token param.

**Join**: `"terminal:{session}:{window}:{pane}"` — server calls `PaneStream.subscribe/1`, returns history.

**Events**:

| Direction | Event | Payload | Notes |
|-----------|-------|---------|-------|
| S→C | `history` | `%{"data" => base64_binary}` | Ring buffer contents, sent once on join |
| S→C | `output` | `%{"data" => base64_binary}` | Streaming terminal output |
| S→C | `pane_dead` | `%{}` | Pane/session ended |
| S→C | `resized` | `%{"cols" => int, "rows" => int}` | Pane was resized by another viewer |
| C→S | `input` | `%{"data" => base64_binary}` | Keyboard/touch input |
| C→S | `resize` | `%{"cols" => int, "rows" => int}` | Client requests pane resize |

**Session management**: The Android app also needs to list/create sessions. Options:
1. **REST API**: Add a simple JSON API (`/api/sessions`, `POST /api/sessions`) protected by bearer token auth. Lightweight — just wraps TmuxManager calls.
2. **Channel-based**: A `SessionChannel` that pushes session list updates. More complex but real-time.

**Recommendation**: REST API for session management (simple, stateless), Channel for terminal I/O (streaming).

```
POST /api/sessions        — create session (body: {"name": "...", "command": "..."})
GET  /api/sessions        — list sessions with panes
DELETE /api/sessions/:name — kill session
```

#### Android App Architecture (high-level)

- **Terminal rendering**: Use [Termux's terminal-emulator](https://github.com/termux/termux-app/tree/master/terminal-emulator) library or a similar Android terminal widget. Receives raw bytes from the Channel, renders natively.
- **WebSocket client**: Use Phoenix's official JavaScript client via a WebView bridge, or a native Kotlin WebSocket client implementing the Phoenix Channel protocol (libraries exist, e.g., `JavaPhoenixClient`).
- **Input**: Android's native keyboard input → convert to terminal bytes → send via Channel `input` event.
- **Offline/reconnect**: Channel automatically reconnects on network drop. On reconnect, re-join the topic — server sends fresh history from the ring buffer. Native terminal clears and re-renders.

### Pane Resize Sync

**Goal**: Viewers can resize the tmux pane, and all viewers stay in sync.

#### Strategy: Last-Writer-Wins with Broadcast

1. Any viewer sends `"resize"` event with `{cols, rows}`.
2. Server calls `tmux resize-pane -t {target} -x {cols} -y {rows}`.
3. PaneStream broadcasts `{:pane_resized, cols, rows}` via PubSub.
4. All *other* viewers receive the broadcast, call `term.resize(cols, rows)` on their xterm.js instance.
5. The viewer that initiated the resize already has the right size — skip the update.

#### Mobile Viewer Behavior

Mobile viewers are **passive resizers** by default:
- On connect, read the pane's current dimensions from `tmux display-message -p -t {target} '#{pane_width} #{pane_height}'`
- Set xterm.js to those dimensions (may require scaling/scrolling on small screens)
- Do NOT send resize events when the mobile viewport changes — instead, scale the terminal via CSS transform or font-size adjustment
- Optional: "Fit to screen" button that sends a resize matching the mobile viewport (with a confirmation since it affects other viewers)

#### Conflict Mitigation

- **Debounce**: All resize events debounced 300ms client-side
- **Throttle**: Server ignores resize events arriving within 500ms of the last resize for the same pane
- **Display feedback**: When another viewer resizes, show a brief toast: "Terminal resized to {cols}x{rows} by another viewer"

### Session Management

**Goal**: Full session lifecycle management from the UI.

#### Features

| Action | UI | tmux command |
|--------|-----|-------------|
| Create session | Form with name + optional command | `tmux new-session -d -s {name} [-x cols -y rows] [command]` |
| Kill session | Confirmation dialog per session | `tmux kill-session -t {name}` |
| Rename session | Inline edit on session name | `tmux rename-session -t {old} {new}` (with name validation) |
| Create window | "+" button within a session | `tmux new-window -t {session}` |
| Kill pane | "x" button on pane in session list | `tmux kill-pane -t {target}` |

#### UI Updates

- Session list cards get action menus (kebab menu / long-press on mobile)
- Confirmation dialogs for destructive actions (kill session/pane)
- Rename uses an inline edit component with Enter to confirm, Esc to cancel
- Actions trigger an immediate session list refresh

#### Safety

- Cannot kill the last pane in a session from the UI (tmux would kill the session — show a "kill session instead?" prompt)
- Rename validation uses the same `^[a-zA-Z0-9_-]+$` regex
- If a viewer is watching a pane that gets killed, they receive the standard `pane_dead` flow

### Multi-Pane Split View

**Goal**: View multiple tmux panes side-by-side in the browser, mirroring tmux's split-pane layout.

#### Approach

- **Session view**: A route `/sessions/:session` shows all panes in that session's current window, laid out to match tmux's actual pane layout
- **Layout discovery**: `tmux list-panes -t {session} -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'` returns pane positions and sizes
- **Rendering**: CSS Grid layout with each pane mapped to a grid area based on its tmux coordinates. Each pane gets its own xterm.js instance and PaneStream subscription.
- **Layout refresh**: Poll `list-panes` periodically (every 2-3s) to detect layout changes (user splits/closes panes via tmux commands)

#### Single-Pane Fallback

- Clicking a specific pane from the session list still opens the full-viewport single-pane view (existing `TerminalLive`)
- The multi-pane view is a new route/LiveView that manages multiple `TerminalHook` instances

#### Mobile Behavior

- Multi-pane view is desktop/tablet only (>640px)
- On mobile, the session view shows a list of panes — tap one to open full-viewport
- Alternatively: horizontal swipe between panes in the same window

### Quick Actions (Command Buttons)

**Goal**: Configurable buttons that send pre-defined commands to the terminal with a single tap — especially valuable on mobile where typing long commands is painful.

#### Configuration File

Quick actions are defined in a YAML configuration file at `~/.config/remote_code_agents/config.yaml`. This file is the central place for all server-side user configuration (auth token, quick actions, and any future settings).

```yaml
# ~/.config/remote_code_agents/config.yaml

# Quick action buttons displayed above the terminal
quick_actions:
  - label: "Push"
    command: "git add . && git commit -m . && git push"
    confirm: true

  - label: "Status"
    command: "git status"

  - label: "Tests"
    command: "mix test"
    color: "green"

  - label: "Deploy"
    command: "./deploy.sh"
    confirm: true
    icon: "rocket"

  - label: "Logs"
    command: "tail -100 /var/log/app.log"
```

#### Configuration Schema

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `label` | string | yes | — | Button text (keep short — 1-2 words) |
| `command` | string | yes | — | Full command string sent to the terminal |
| `confirm` | boolean | no | `false` | Show confirmation dialog before executing |
| `color` | string | no | `"default"` | Button color hint: `"default"`, `"green"`, `"red"`, `"yellow"`, `"blue"` |
| `icon` | string | no | `null` | Optional icon name (Heroicons subset: `"rocket"`, `"play"`, `"stop"`, `"trash"`, `"arrow-up"`, `"terminal"`) |

#### Config Loading

- **Location resolution**: Check `$RCA_CONFIG_PATH` env var first, then `~/.config/remote_code_agents/config.yaml`, then fall back to defaults (no quick actions).
- **Parsing**: Use `yaml_elixir` hex package to parse YAML.
- **Loading**: A `RemoteCodeAgents.Config` module reads and validates the config at application startup.
- **Reloading**: Config is re-read on each LiveView mount (cheap — it's a small file). This means editing the YAML takes effect on the next page load with no server restart.
- **Validation**: On load, validate each quick action entry. Log warnings for invalid entries (missing `label`/`command`, unknown `color`) and skip them rather than crashing.
- **Missing file**: If no config file exists, the app runs with defaults — no quick actions shown, no error.

```elixir
defmodule RemoteCodeAgents.Config do
  @default_path "~/.config/remote_code_agents/config.yaml"

  @doc """
  Reads and validates the user config file.
  Returns a map with validated settings, falling back to defaults for missing/invalid values.
  """
  def load do
    path = config_path() |> Path.expand()

    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> parse(yaml)
      {:error, _} -> defaults()
    end
  end

  defp config_path do
    System.get_env("RCA_CONFIG_PATH") || @default_path
  end

  defp defaults do
    %{quick_actions: []}
  end

  defp parse(yaml) do
    actions =
      yaml
      |> Map.get("quick_actions", [])
      |> Enum.filter(&valid_action?/1)
      |> Enum.map(&normalize_action/1)

    %{quick_actions: actions}
  end

  defp valid_action?(%{"label" => l, "command" => c}) when is_binary(l) and is_binary(c), do: true
  defp valid_action?(entry) do
    require Logger
    Logger.warning("Skipping invalid quick action entry: #{inspect(entry)}")
    false
  end

  defp normalize_action(entry) do
    %{
      label: entry["label"],
      command: entry["command"],
      confirm: entry["confirm"] == true,
      color: validate_color(entry["color"]),
      icon: entry["icon"]
    }
  end

  @valid_colors ~w(default green red yellow blue)
  defp validate_color(c) when c in @valid_colors, do: c
  defp validate_color(_), do: "default"
end
```

#### UI: Quick Action Bar

A horizontally-scrollable toolbar rendered above the terminal, below the session header.

**Desktop (>640px)**:
```
┌─────────────────────────────────────────────────────────┐
│ ← session-name:0.0                              [gear] │  ← header
├─────────────────────────────────────────────────────────┤
│ [Status] [Push ⚠] [Tests] [Deploy ⚠] [Logs]           │  ← quick action bar
├─────────────────────────────────────────────────────────┤
│                                                         │
│  terminal content...                                    │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Mobile (<640px)**:
```
┌──────────────────────────┐
│ ← session:0.0     [gear] │  ← header (auto-hides)
├──────────────────────────┤
│ [Status] [Push ⚠] [Te ► │  ← scrollable action bar
├──────────────────────────┤
│                          │
│  terminal content...     │
│                          │
├──────────────────────────┤
│ [Esc][Tab][Ctrl][↑][↓][←]│  ← virtual key toolbar
└──────────────────────────┘
```

- Buttons use compact pill-style styling with color-coded borders/backgrounds
- `⚠` indicator on buttons with `confirm: true`
- The bar is collapsible (toggle via a small chevron) to reclaim vertical space
- If no quick actions are configured, the bar is not rendered at all
- Horizontal scroll with momentum/snap on mobile (CSS `overflow-x: auto; scroll-snap-type: x mandatory;`)

#### LiveView Integration

`TerminalLive` loads quick actions on mount and assigns them to the socket:

```elixir
# terminal_live.ex
def mount(params, _session, socket) do
  config = RemoteCodeAgents.Config.load()

  socket =
    socket
    |> assign(:quick_actions, config.quick_actions)
    # ... existing assigns ...

  {:ok, socket}
end
```

The template renders the action bar:

```heex
<%!-- terminal_live.html.heex --%>
<div :if={@quick_actions != []} class="quick-action-bar flex gap-2 overflow-x-auto px-2 py-1 bg-gray-900 border-b border-gray-700">
  <button
    :for={action <- @quick_actions}
    phx-click="quick_action"
    phx-value-index={Enum.find_index(@quick_actions, &(&1 == action))}
    class={["quick-action-btn px-3 py-1 rounded-full text-sm whitespace-nowrap",
            action_color_class(action.color)]}
  >
    <%= action.label %><%= if action.confirm, do: " ⚠" %>
  </button>
</div>
```

The event handler sends the command as keystrokes:

```elixir
def handle_event("quick_action", %{"index" => index_str}, socket) do
  index = String.to_integer(index_str)
  action = Enum.at(socket.assigns.quick_actions, index)

  if action do
    if action.confirm do
      {:noreply, assign(socket, :pending_action, action)}
    else
      send_quick_action(socket, action)
    end
  else
    {:noreply, socket}
  end
end

def handle_event("confirm_action", _params, socket) do
  case socket.assigns[:pending_action] do
    nil -> {:noreply, socket}
    action ->
      socket = assign(socket, :pending_action, nil)
      send_quick_action(socket, action)
  end
end

def handle_event("cancel_action", _params, socket) do
  {:noreply, assign(socket, :pending_action, nil)}
end

defp send_quick_action(socket, action) do
  # Send the command text followed by Enter (newline) as a binary
  command_with_enter = action.command <> "\n"
  PaneStream.send_keys(socket.assigns.target, command_with_enter)
  {:noreply, socket}
end
```

#### Confirmation Dialog

For actions with `confirm: true`, a modal overlay appears:

```heex
<div :if={@pending_action} class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
  <div class="bg-gray-800 rounded-lg p-4 mx-4 max-w-sm w-full">
    <p class="text-white mb-2">Run this command?</p>
    <pre class="bg-gray-900 text-green-400 p-2 rounded text-sm mb-4 overflow-x-auto"><%= @pending_action.command %></pre>
    <div class="flex gap-2 justify-end">
      <button phx-click="cancel_action" class="px-4 py-2 text-gray-400">Cancel</button>
      <button phx-click="confirm_action" class="px-4 py-2 bg-blue-600 text-white rounded">Run</button>
    </div>
  </div>
</div>
```

#### Execution Model

Quick actions use the **exact same input path** as regular typing:
1. Command string is converted to bytes
2. Sent via `PaneStream.send_keys/2` → `tmux send-keys -H`
3. The terminal shows the command being "typed" and executed

This means:
- The command appears in the terminal's history (visible, auditable)
- Shell features work normally (aliases, env vars, pipes, `&&`)
- If the terminal is at a non-shell prompt (e.g., a `vim` session, a REPL), the keys are sent as-is — the user sees what happens, just like typing
- Ctrl-C can cancel a running command started via quick action

#### Dependencies

Add `yaml_elixir` (parser) and `ymlr` (encoder) to `mix.exs`:

```elixir
defp deps do
  [
    # ... existing deps ...
    {:yaml_elixir, "~> 2.11"},
    {:ymlr, "~> 5.0"},
  ]
end
```

### Settings & Quick Actions Management UI + API

**Goal**: Allow users to manage quick actions and application settings through the web UI (and via a REST API for the native Android app), in addition to hand-editing the YAML config file.

#### Design Principles

- **YAML remains the source of truth**: The UI and API read from and write to `~/.config/remote_code_agents/config.yaml`. No database introduced.
- **Round-trip safe**: The YAML writer rewrites the file cleanly using `ymlr` (a YAML encoder library) with a header comment explaining the format. Comments in the original file are not preserved — this is acceptable since the structure is simple and the header documents the format.
- **Immediate effect**: After a save, the updated config is available on the next LiveView mount (already the case — config is re-read per mount).
- **Conflict-free**: Single-user tool — no concurrent write concerns. The UI reads the current file, presents it for editing, and writes it back atomically (write to temp file + rename).

#### Web UI: Settings Panel

Accessible via a gear icon in the terminal header or session list.

**Quick Actions Management**:
```
┌─ Settings ──────────────────────────────────────────────┐
│                                                         │
│  Quick Actions                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │ [Status]  git status                    [✎] [✕] │    │
│  │ [Push ⚠]  git add . && git commit ...   [✎] [✕] │    │
│  │ [Tests]   mix test                      [✎] [✕] │    │
│  └─────────────────────────────────────────────────┘    │
│  [+ Add Quick Action]                                   │
│                                                         │
│  ── Add / Edit Quick Action ──                          │
│  Label:   [________]                                    │
│  Command: [________________________]                    │
│  Color:   [default ▾]                                   │
│  ☐ Confirm before running                               │
│                    [Cancel] [Save]                       │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

- Drag-to-reorder support (sets display order in the YAML list)
- Inline edit and delete with confirmation
- Mobile-friendly: full-screen panel with large touch targets

#### LiveView Implementation

A new LiveView or LiveComponent for the settings panel:

```elixir
defmodule RemoteCodeAgentsWeb.SettingsLive do
  use RemoteCodeAgentsWeb, :live_view

  def mount(_params, _session, socket) do
    config = RemoteCodeAgents.Config.load()
    {:ok, assign(socket, :config, config)}
  end

  def handle_event("save_action", %{"action" => action_params}, socket) do
    config = socket.assigns.config
    updated = RemoteCodeAgents.Config.upsert_action(config, action_params)
    RemoteCodeAgents.Config.save(updated)
    {:noreply, assign(socket, :config, updated)}
  end

  def handle_event("delete_action", %{"index" => index}, socket) do
    config = socket.assigns.config
    updated = RemoteCodeAgents.Config.delete_action(config, String.to_integer(index))
    RemoteCodeAgents.Config.save(updated)
    {:noreply, assign(socket, :config, updated)}
  end

  def handle_event("reorder_actions", %{"order" => order}, socket) do
    config = socket.assigns.config
    updated = RemoteCodeAgents.Config.reorder_actions(config, order)
    RemoteCodeAgents.Config.save(updated)
    {:noreply, assign(socket, :config, updated)}
  end
end
```

#### Config Module Extensions

Add write capabilities to `RemoteCodeAgents.Config`:

```elixir
defmodule RemoteCodeAgents.Config do
  # ... existing load/parse functions ...

  @doc "Write config back to YAML file atomically."
  def save(config) do
    path = config_path() |> Path.expand()
    yaml = to_yaml(config)
    tmp = path <> ".tmp"

    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, yaml)
    File.rename!(tmp, path)
    :ok
  end

  defp to_yaml(config) do
    """
    # Remote Code Agents configuration
    # Edit this file directly or use the web UI at /settings
    #
    # Quick actions appear as buttons above the terminal.
    # Fields: label (required), command (required), confirm, color, icon

    """ <> Ymlr.document!(%{
      "quick_actions" => Enum.map(config.quick_actions, &action_to_map/1)
    })
  end

  def upsert_action(config, params) do
    # ... validate and insert/update action in config.quick_actions
  end

  def delete_action(config, index) do
    %{config | quick_actions: List.delete_at(config.quick_actions, index)}
  end

  def reorder_actions(config, new_order) do
    # new_order is a list of indices representing the desired order
    reordered = Enum.map(new_order, &Enum.at(config.quick_actions, &1))
    %{config | quick_actions: reordered}
  end
end
```

#### REST API (for Android App)

Extends the future REST API (described in Future 2) with config endpoints:

```
GET    /api/config              — returns full config as JSON
GET    /api/quick-actions       — returns quick actions list
POST   /api/quick-actions       — add a new quick action
PUT    /api/quick-actions/:index — update a quick action
DELETE /api/quick-actions/:index — delete a quick action
PUT    /api/quick-actions/order — reorder quick actions (body: {"order": [2,0,1]})
```

All endpoints require the same bearer token auth as other API routes.

**Response format**:
```json
{
  "quick_actions": [
    {"label": "Status", "command": "git status", "confirm": false, "color": "default", "icon": null},
    {"label": "Push", "command": "git add . && git commit -m . && git push", "confirm": true, "color": "default", "icon": null}
  ]
}
```

#### Controller

```elixir
defmodule RemoteCodeAgentsWeb.QuickActionController do
  use RemoteCodeAgentsWeb, :controller

  def index(conn, _params) do
    config = RemoteCodeAgents.Config.load()
    json(conn, %{quick_actions: config.quick_actions})
  end

  def create(conn, %{"action" => action_params}) do
    config = RemoteCodeAgents.Config.load()
    updated = RemoteCodeAgents.Config.upsert_action(config, action_params)
    RemoteCodeAgents.Config.save(updated)
    json(conn, %{quick_actions: updated.quick_actions})
  end

  def update(conn, %{"index" => index, "action" => action_params}) do
    config = RemoteCodeAgents.Config.load()
    updated = RemoteCodeAgents.Config.update_action(config, String.to_integer(index), action_params)
    RemoteCodeAgents.Config.save(updated)
    json(conn, %{quick_actions: updated.quick_actions})
  end

  def delete(conn, %{"index" => index}) do
    config = RemoteCodeAgents.Config.load()
    updated = RemoteCodeAgents.Config.delete_action(config, String.to_integer(index))
    RemoteCodeAgents.Config.save(updated)
    json(conn, %{quick_actions: updated.quick_actions})
  end

  def reorder(conn, %{"order" => order}) do
    config = RemoteCodeAgents.Config.load()
    updated = RemoteCodeAgents.Config.reorder_actions(config, order)
    RemoteCodeAgents.Config.save(updated)
    json(conn, %{quick_actions: updated.quick_actions})
  end
end
```

#### Routes

```elixir
# router.ex
scope "/api", RemoteCodeAgentsWeb do
  pipe_through [:api, :require_auth_token]

  resources "/quick-actions", QuickActionController, only: [:index, :create, :update, :delete]
  put "/quick-actions/order", QuickActionController, :reorder
end

live "/settings", SettingsLive
```

### User Preferences

**Goal**: Configurable font size, color theme, and other display settings.

#### Settings

| Setting | Options | Default | Storage |
|---------|---------|---------|---------|
| Font size | 8-24px, or "fit to screen" | 14px | `localStorage` |
| Font family | Monospace font selection | System monospace | `localStorage` |
| Color theme | Dark, light, solarized, custom | Dark (xterm.js default) | `localStorage` |
| Cursor style | Block, underline, bar | Block | `localStorage` |
| Cursor blink | On/off | On | `localStorage` |
| Scrollback limit | 1k-100k lines | 10k | `localStorage` |
| Virtual toolbar | Show/hide, key selection | Show | `localStorage` |

#### Implementation

- **Settings panel**: Slide-out panel or modal, accessible from a gear icon in the header/toolbar
- **xterm.js options**: All settings map directly to xterm.js `Terminal` constructor options — apply on change, no server round-trip needed
- **Persistence**: `localStorage` keyed by `rca-preferences`. Read on hook mount, applied before terminal is displayed.
- **Per-device**: Stored client-side, so mobile and desktop can have different settings naturally
- **No server involvement**: This is purely a client-side feature. No API, no config, no storage needed server-side.

```javascript
// terminal_hook.js — preference loading
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

---

## Deployment

### Mix Release

The primary deployment target is a Mix release — a self-contained package with the Erlang runtime.

```bash
# Build
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release

# Run
RCA_AUTH_TOKEN="my-secret-token" _build/prod/rel/remote_code_agents/bin/remote_code_agents start
```

### Requirements

- tmux installed on the host (not bundled in the release)
- No database, no Redis, no external services
- Erlang/OTP runtime is bundled in the release (no system Erlang needed if `include_erts: true`)

### Systemd Service (optional)

```ini
[Unit]
Description=Remote Code Agents
After=network.target

[Service]
Type=exec
User=ben
Environment=RCA_AUTH_TOKEN=<token>
Environment=HOME=/home/ben
ExecStart=/opt/remote_code_agents/bin/remote_code_agents start
ExecStop=/opt/remote_code_agents/bin/remote_code_agents stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Docker (alternative)

```dockerfile
FROM elixir:1.16-slim AS build
# ... standard Phoenix Dockerfile ...

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y tmux && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/_build/prod/rel/remote_code_agents /app
CMD ["/app/bin/remote_code_agents", "start"]
```

**Docker caveat**: The app needs access to the host's tmux server. Options:
1. Run tmux inside the container (limits usefulness — can't attach to host sessions)
2. Mount the host's tmux socket: `-v /tmp/tmux-$(id -u):/tmp/tmux-$(id -u)` — allows the container to talk to the host's tmux server
3. **Recommendation**: Native deployment (Mix release) is simpler for this use case since the app is inherently tied to the host's tmux

---

## Implementation Prioritization

| Priority | Feature | Effort | Rationale |
|----------|---------|--------|-----------|
| P1 | Auth + remote access | Medium | Required to use from mobile — the primary motivation |
| P2 | Pane resize sync | Small | Quality-of-life, simple to implement |
| P3 | Session management (kill, rename) | Small | Basic lifecycle control |
| P4 | Quick actions (command buttons) | Small | High-value for mobile; simple config + UI |
| P5 | User preferences (font, theme) | Small | Client-side only, no server changes |
| P6 | Phoenix Channel + Android client | Large | New client platform, significant effort |
| P7 | Multi-pane split view | Medium | Nice-to-have, complex layout logic |

