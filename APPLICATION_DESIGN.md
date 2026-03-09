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

2. **Native Android (Phoenix Channel)**: Connects directly to a `TerminalChannel` via a dedicated WebSocket. Speaks a simple binary/JSON protocol. This is **post-MVP** — the Channel is not needed for the web client.

3. **Shared backend**: Both LiveView processes and Channel processes subscribe to the same PubSub topics and call the same PaneStream API. No terminal logic is duplicated.

```
Web browser:
  xterm.js ↔ TerminalHook ↔ LiveView push_event/handle_event ↔ PaneStream

Android app (post-MVP):
  TerminalView ↔ TerminalChannel ↔ PaneStream
```

### Key Modules

#### `RemoteCodeAgents.TmuxManager`
- **Responsibility**: Discover, list, and create tmux sessions
- **Interface**:
  - `list_sessions/0` — returns `[%Session{name, windows, created, attached?}]`
  - `list_panes/1` — returns panes for a given session/window
  - `create_session/1` — creates a new tmux session with given name, returns session info
  - `kill_session/1` — terminates a session
  - `session_exists?/1` — check if a session is still alive
- **Implementation**: Shells out to `tmux list-sessions`, `tmux list-windows`, `tmux list-panes`, `tmux new-session` with format strings; parses output
- **Session name validation**: Names must match `^[a-zA-Z0-9_-]+$` (alphanumeric, hyphens, underscores). Reject anything else at creation time. This prevents conflicts with the tmux target format `session:window.pane` where colons and periods are delimiters.
- **Not a GenServer for MVP**: Stateless module with functions that shell out. No need to cache session state since the source of truth is tmux itself. Can be promoted to a GenServer later if we need to rate-limit tmux CLI calls.

#### `RemoteCodeAgents.PaneStream`
- **Responsibility**: Bidirectional bridge between a tmux pane and one or more viewers
- **Registration**: Via `Registry` with key `{:pane, target}` where `target` is the `"session:window.pane"` string. Lookup via `Registry.lookup(RemoteCodeAgents.PaneRegistry, {:pane, target})`.
- **State**:
  - `target` — the `session:window.pane` identifier
  - `pipe_port` — Elixir Port running `cat` on the FIFO
  - `viewers` — `MapSet` of subscriber PIDs (monitored)
  - `buffer` — ring buffer of recent output (configurable max size, default 64KB) for late-joining viewers
  - `scrollback` — initial scrollback binary captured at startup
  - `status` — `:streaming | :dead`
- **Interface**:
  - `start_link/1` — starts streaming for a target pane
  - `subscribe/1` — adds a viewer, monitors the viewer PID, returns `{:ok, scrollback, recent_buffer}`. Starts the PaneStream via DynamicSupervisor if not already running.
  - `unsubscribe/1` — removes a viewer. If no viewers remain, starts the grace period timer.
  - `send_keys/2` — sends input to the pane via `tmux send-keys`
- **Lifecycle**:
  - Created on first `subscribe/1` call (via a `get_or_start/1` helper that checks Registry then starts under DynamicSupervisor)
  - Monitors all viewer PIDs — auto-unsubscribes on viewer crash/disconnect
  - On last viewer unsubscribe: starts a configurable grace period timer (default 5s). If a new viewer subscribes within the grace period, cancel the timer. Otherwise, shut down (detach pipe-pane, clean up FIFO, terminate).
  - On Port EOF (tmux pane died): set status to `:dead`, broadcast `{:pane_dead, target}` to all viewers, clean up FIFO, shut down after viewers acknowledge/disconnect.

#### `RemoteCodeAgents.Tmux.CommandRunner`
- **Responsibility**: Execute tmux CLI commands and return parsed output
- **Interface**:
  - `run/1` — executes a tmux command, returns `{:ok, output}` or `{:error, reason}`
  - `run!/1` — same but raises on error
- **Rationale**: Single point of contact with the tmux CLI. Makes it easy to mock in tests and add logging/rate-limiting later.
- **Implementation**: Uses `System.cmd/3` with stderr capture. Validates that `tmux` is available on startup.

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
     — This opens the write end of the FIFO, unblocking the `cat` reader
  5. Capture initial scrollback: tmux capture-pane -p -e -S -{max_lines} -t {target}
     — Done AFTER pipe-pane attach so no output is lost between steps
     — Any output generated between steps 4 and 5 will appear in both
       the pipe stream and the scrollback capture (minor duplication, but
       xterm.js handles redrawn content gracefully)
```

**Startup sequence rationale**: The key insight is that `cat` on a FIFO blocks at the OS level until a writer opens the pipe, but since it's a Port (separate OS process), it doesn't block the Elixir GenServer. The GenServer can proceed to call `pipe-pane` which opens the write end, unblocking `cat`. This avoids the FIFO deadlock without needing `O_NONBLOCK` or `O_RDWR` hacks.

Scrollback is captured *after* pipe-pane is attached. This means there's a brief window where output appears in both the pipe stream and the scrollback capture. This is acceptable — xterm.js re-rendering overlapping content is invisible to the user, and it's far better than the alternative (capturing scrollback first and missing output between capture and pipe-pane attach).

**Shutdown sequence:**

```
PaneStream shutdown:
  1. Detach pipe: tmux pipe-pane -t {target}   (no -o flag = detach)
  2. Close the Port (sends SIGTERM to cat, which closes the FIFO read end)
  3. Remove the FIFO: File.rm({fifo_path})
```

**Crash recovery**: If PaneStream crashes, the supervisor restarts it. The `init/1` callback must:
  1. Check for and remove stale FIFO from previous instance
  2. Detach any existing pipe-pane on the target (`tmux pipe-pane -t {target}`)
  3. Re-run the normal startup sequence

**FIFO naming**: Target strings like `mysession:0.1` are sanitized for filesystem use by replacing `:` and `.` with `-`, giving FIFO names like `pane-mysession-0-1.fifo`.

### Input Handling (send-keys)

**Problem**: `tmux send-keys -l` (literal mode) sends text literally but does **not** handle control characters. xterm.js `onData` emits raw terminal data including escape sequences (`\x03` for Ctrl+C, `\x1b[A` for arrow up, etc.). These must reach tmux correctly.

**Solution**: Use `tmux send-keys -H` (hex mode) for all input. Convert each byte from xterm.js `onData` to its two-character hex representation and pass them as arguments to `send-keys -H`.

```
Example: User types "hi" then Ctrl+C
  xterm.js onData emits: "hi\x03"
  Sent to server as: %{"data" => "hi\x03"}
  PaneStream calls: tmux send-keys -H -t {target} 68 69 03
```

**Why hex mode for everything**: Simpler than branching between `-l` for printable chars and raw mode for control chars. No escaping edge cases. Works uniformly for all input including Unicode (send UTF-8 bytes as hex).

**Performance**: For typical interactive use, `send-keys -H` with a handful of hex bytes per keystroke is negligible overhead. For bulk paste operations, we batch into a single `send-keys -H` call with all bytes.

### LiveView Pages

#### `RemoteCodeAgentsWeb.SessionListLive`
- Route: `/`
- Lists all active tmux sessions with their windows and panes
- "New Session" button/form — creates a new tmux session (name input with validation, optional starting command)
- Auto-refreshes session list via `Process.send_after(self(), :refresh_sessions, 3_000)` in `handle_info`
- Click a pane to navigate to the terminal view via `push_navigate`
- Shows pane dimensions and running command (from `tmux list-panes -F` format)
- Mobile layout: full-width card list, large touch targets
- Empty state: friendly message when no tmux sessions exist, with prominent "Create Session" CTA

#### `RemoteCodeAgentsWeb.TerminalLive`
- Route: `/sessions/:session/:window/:pane`
- Full-viewport xterm.js terminal
- **LiveView Hook (`TerminalHook`)**:
  - `mounted()`: Creates xterm.js `Terminal` + `FitAddon`, opens terminal in container div, calls `FitAddon.fit()`, sends initial `resize` event to server
  - `onData`: xterm.js keyboard input → `this.pushEvent("key_input", {data: rawBytes})`
  - `onResize`: debounced (300ms) → `this.pushEvent("resize", {cols, rows})`
  - Server pushes `"output"` → `term.write(data)`
  - Server pushes `"scrollback"` → `term.write(data)` (before streaming begins)
  - Server pushes `"pane_dead"` → display overlay message "Session ended", offer link back to session list
  - Clipboard: `onSelectionChange` → auto-copy to clipboard; paste handler intercepts Ctrl+Shift+V / toolbar button
  - `destroyed()`: Clean up xterm.js instance
- **Server side** (`handle_params/3`):
  - Calls `PaneStream.subscribe(target)` — gets `{:ok, scrollback, recent_buffer}`
  - Pushes scrollback + recent buffer to client via `push_event`
  - Subscribes to PubSub topic `"pane:#{target}"`
  - `handle_info({:pane_output, data})` → `push_event(socket, "output", %{data: data})`
  - `handle_info({:pane_dead, _target})` → `push_event(socket, "pane_dead", %{})`
  - `handle_event("key_input", %{"data" => data})` → `PaneStream.send_keys(target, data)`
  - `handle_event("resize", %{"cols" => c, "rows" => r})` → resize handling (see Resize Conflicts below)
  - `terminate/2`: calls `PaneStream.unsubscribe(target)`
- Mobile: on-screen virtual keyboard toolbar (see Mobile UI section)
- Back button / navigation header to return to session list

### Phoenix Channel: `TerminalChannel` (Post-MVP)

For native Android client only. Not used by the web UI.

- Topic: `"terminal:{session}:{window}:{pane}"`
- **Client → Server events**:
  - `"input"` — `%{"data" => binary}` — keyboard input
  - `"resize"` — `%{"cols" => int, "rows" => int}`
- **Server → Client events**:
  - `"output"` — `%{"data" => binary}` — terminal output bytes
  - `"scrollback"` — `%{"data" => binary}` — initial scrollback history on join
  - `"pane_dead"` — pane/session no longer exists
- **Join handler**: Calls `PaneStream.subscribe/1`, subscribes to PubSub, same as TerminalLive
- **Auth**: Token-based authentication on join (post-MVP)

## Data Flow

### Terminal Output (tmux → browser)

1. tmux writes output → `pipe-pane` writes to FIFO
2. `cat` Port reads from FIFO → Elixir receives `{port, {:data, bytes}}`
3. PaneStream appends to ring buffer, broadcasts `{:pane_output, bytes}` via PubSub topic `"pane:#{target}"`
4. `TerminalLive` receives via `handle_info`, calls `push_event(socket, "output", %{data: Base.encode64(bytes)})`
5. `TerminalHook` decodes base64, calls `term.write(bytes)` on xterm.js instance

Note: Binary data is base64-encoded for LiveView push_event since LiveView events are JSON-serialized. For the post-MVP Channel implementation, raw binary frames can be used instead.

### Initial Attach (scrollback)

1. Viewer calls `PaneStream.subscribe(target)`
2. If PaneStream not running, `get_or_start/1` starts it under DynamicSupervisor:
   a. Port starts `cat` on FIFO (blocks at OS level, not in GenServer)
   b. `pipe-pane` attached (unblocks `cat`)
   c. `capture-pane` captures scrollback
3. PaneStream returns `{:ok, scrollback_binary, recent_ring_buffer}`
4. TerminalLive pushes scrollback to client as `"scrollback"` event
5. Client writes scrollback to xterm.js, then streaming output follows

For late-joining viewers (PaneStream already running):
1. `subscribe/1` returns the cached scrollback + current ring buffer contents
2. Ring buffer ensures late joiners see recent context even if they missed the live stream
3. PubSub subscription starts, new output flows normally

### Keyboard Input (browser → tmux)

1. xterm.js `onData` callback fires with raw terminal bytes
2. Hook calls `this.pushEvent("key_input", {data: rawBytes})`
3. `TerminalLive.handle_event("key_input", %{"data" => data})` calls `PaneStream.send_keys(target, data)`
4. PaneStream converts bytes to hex, executes `tmux send-keys -H -t {target} {hex_bytes}`

### Pane Resize

1. xterm.js / FitAddon reports new dimensions after browser resize or orientation change
2. Hook debounces (300ms), sends `this.pushEvent("resize", {cols, rows})`
3. TerminalLive receives `handle_event("resize", ...)` — see Resize Conflict Resolution below

### Pane Death

1. tmux pane exits (process ends, user runs `exit`, session killed externally)
2. `pipe-pane` closes the write end of the FIFO
3. `cat` Port receives EOF, exits with status 0
4. PaneStream receives `{port, {:exit_status, 0}}` in `handle_info`
5. PaneStream sets status to `:dead`, broadcasts `{:pane_dead, target}` via PubSub
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

**MVP simplification**: For MVP, resizing is disabled entirely — the pane keeps whatever dimensions it had when created. Viewers fit xterm.js to the existing pane size. This is noted in the MVP scope.

## Bandwidth Optimization

For low-bandwidth / high-latency connections:

1. **Streaming, not polling**: pipe-pane delivers only actual output — no wasted bandwidth on unchanged frames
2. **Base64 encoding overhead**: LiveView requires JSON-safe event payloads, so binary terminal data is base64-encoded (~33% overhead). Acceptable for terminal text. For the post-MVP Channel, raw binary frames eliminate this overhead.
3. **Compression**: Enable WebSocket per-message deflate compression in Phoenix endpoint config — terminal output (mostly text + ANSI codes) compresses very well
4. **Debounced resize**: Client debounces resize events (300ms) to avoid flooding during orientation changes
5. **Input batching**: Buffer rapid keystrokes client-side and send in batches (configurable, e.g. every 16ms) to reduce round-trip count
6. **Scrollback cap**: Limit initial scrollback to configurable max (default 10,000 lines) to avoid a huge payload on attach
7. **Ring buffer cap**: Recent output buffer capped at 64KB — enough context for late joiners without excessive memory or transfer

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
| Terminal rendering | xterm.js 5.x        | Battle-tested terminal emulator; handles ANSI, cursor  |
| xterm.js addons    | @xterm/addon-fit    | Required — auto-sizes terminal to container            |
|                    | @xterm/addon-web-links | Nice-to-have — makes URLs clickable in terminal     |
| CSS                | Tailwind CSS 3.x    | Ships with Phoenix 1.7+; utility-first, good for responsive |
| Terminal backend   | tmux pipe-pane      | True streaming, lower latency than polling              |
| Process registry   | Elixir Registry     | Built-in, lightweight process lookup by key            |
| Process management | DynamicSupervisor   | One child per active pane stream                       |
| Pub/Sub            | Phoenix.PubSub      | Built-in; connects PaneStreams to viewers               |
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
      pane_stream.ex                # Per-pane streaming GenServer (pipe-pane + FIFO)
      pane_stream_supervisor.ex     # DynamicSupervisor for PaneStreams
    remote_code_agents_web/
      channels/                     # Post-MVP
        terminal_channel.ex         # Raw terminal I/O channel (for native clients)
        user_socket.ex              # Socket configuration
      live/
        session_list_live.ex        # Session listing + creation page
        session_list_live.html.heex # Template
        terminal_live.ex            # Terminal view page
        terminal_live.html.heex     # Template
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
  # Max scrollback lines to capture on initial attach
  max_scrollback_lines: 10_000,
  # Grace period (ms) before shutting down a PaneStream with zero viewers
  pane_stream_grace_period: 5_000,
  # Ring buffer max size (bytes) for recent output
  ring_buffer_size: 65_536,
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
- **Channel auth**: `TerminalChannel` (post-MVP) must verify auth token on join to prevent unauthorized WebSocket connections from native apps
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

1. **Capture strategy → pipe-pane**: True streaming via `tmux pipe-pane` to a FIFO, read by a `cat` Port. Initial scrollback captured separately via `capture-pane -p -e -S -`. The startup sequence (Port first, then pipe-pane, then capture-pane) avoids both FIFO deadlock and missed output.

2. **Scrollback → Yes**: Capture full scrollback (up to configurable max) on initial attach. Sent to client as a `"scrollback"` event before streaming begins. Late joiners also get the ring buffer of recent output.

3. **Multiple viewers → Shared PaneStream**: One PaneStream per pane, shared across all viewers via PubSub. Reference-counted via monitored PIDs with a grace period on last-viewer-disconnect.

4. **Session creation → Yes**: The session list page always shows a "New Session" option alongside existing sessions. User provides a session name (validated: alphanumeric/hyphens/underscores only); optionally a starting command.

5. **Clipboard → Yes**: Copy via xterm.js selection + Clipboard API. Paste via toolbar button (mobile) or Ctrl+Shift+V (desktop). Requires secure context (localhost or HTTPS). Fallback to execCommand for older browsers.

6. **Web transport → LiveView push_event**: Terminal I/O on web flows through the existing LiveView WebSocket. No second WebSocket connection. Phoenix Channel is post-MVP, only for native Android client.

7. **Input encoding → send-keys -H (hex)**: All input bytes converted to hex and sent via `tmux send-keys -H`. Handles printable text, control characters, and escape sequences uniformly. No branching between literal and raw modes.

8. **FIFO blocking → cat Port**: The `cat` command runs as a Port (separate OS process), blocking on FIFO open without blocking the GenServer. `pipe-pane` opens the write end, unblocking `cat`. Simple and reliable.

9. **Process lookup → Elixir Registry**: PaneStreams registered in `RemoteCodeAgents.PaneRegistry` with key `{:pane, target}`. `get_or_start/1` checks Registry, starts under DynamicSupervisor if not found.

10. **Resize conflicts → MVP: disabled**: For MVP, panes keep their existing dimensions and viewers adapt. Post-MVP: last-writer-wins with dimension broadcast to all viewers; mobile viewers are passive (read-only resize).

11. **Session name validation → strict**: Only `^[a-zA-Z0-9_-]+$` allowed. Prevents tmux target format breakage from colons/periods in names.

## MVP Scope

For the first working version:

1. List tmux sessions and panes on the index page
2. Create new tmux sessions from the UI (with name validation)
3. Click a pane to open a full-viewport terminal view with xterm.js
4. Stream output from the pane using pipe-pane (with scrollback on attach)
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
| User preferences       | Browser `localStorage` (client-side)                   |
| Layout preferences     | Browser `localStorage` (client-side)                   |

**Rationale**: tmux is the source of truth for all terminal state. Runtime coordination lives in GenServer memory and PubSub. Auth is single-user, handled by a static token. User preferences (font size, theme, layout) are per-device and belong in the browser. There is no data that requires durable server-side storage.

**Implications**:
- No Ecto dependency, no migrations, no database process to manage
- Application restarts are clean — PaneStreams re-attach to existing tmux sessions on demand
- Deployment is a single binary (Mix release) with zero infrastructure dependencies beyond tmux
- If multi-user support is ever needed (unlikely for this tool's use case), a database could be introduced then

---

## Post-MVP Features

### Post-MVP 1: Authentication & Remote Access

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

### Post-MVP 2: Phoenix Channel + Native Android Client

**Goal**: Android app connects directly to the server via WebSocket, renders terminal natively.

#### Channel Protocol

The `TerminalChannel` speaks a simple protocol over the Phoenix Channel WebSocket:

**Connection**: Client connects to `wss://host:port/socket/websocket` with token param.

**Join**: `"terminal:{session}:{window}:{pane}"` — server calls `PaneStream.subscribe/1`, returns scrollback.

**Events**:

| Direction | Event | Payload | Notes |
|-----------|-------|---------|-------|
| S→C | `scrollback` | `%{"data" => base64_binary}` | Sent once on join |
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
- **Offline/reconnect**: Channel automatically reconnects on network drop. On reconnect, re-join the topic — server sends fresh scrollback + ring buffer. xterm.js/native terminal clears and re-renders.

### Post-MVP 3: Pane Resize Sync

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

### Post-MVP 4: Session Management

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

### Post-MVP 5: Multi-Pane Split View

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

### Post-MVP 6: User Preferences

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

## Post-MVP Prioritization

| Priority | Feature | Effort | Rationale |
|----------|---------|--------|-----------|
| P1 | Auth + remote access | Medium | Required to use from mobile — the primary motivation |
| P2 | Pane resize sync | Small | Quality-of-life, simple to implement |
| P3 | Session management (kill, rename) | Small | Basic lifecycle control |
| P4 | User preferences (font, theme) | Small | Client-side only, no server changes |
| P5 | Phoenix Channel + Android client | Large | New client platform, significant effort |
| P6 | Multi-pane split view | Medium | Nice-to-have, complex layout logic |

## MVP Scope

For the first working version:

1. List tmux sessions and panes on the index page
2. Create new tmux sessions from the UI (with name validation)
3. Click a pane to open a full-viewport terminal view with xterm.js
4. Stream output from the pane using pipe-pane (with scrollback on attach)
5. Send keyboard input from the browser to the pane (via send-keys -H)
6. Shared PaneStream with viewer ref counting and grace period
7. Clipboard copy/paste
8. Mobile-responsive layout with virtual key toolbar
9. Bind to localhost only (no auth needed)
10. Pane death detection and user notification
11. Error handling (tmux not installed, pane died, FIFO errors)
12. Resize disabled — viewers adapt to existing pane dimensions
