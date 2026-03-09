# Remote Code Agents - Application Design

## Overview

A web application built with Elixir, Phoenix, and LiveView that runs on a host computer and provides a browser-based interface to interact with running tmux sessions. This enables remote access to terminal sessions — particularly useful for monitoring and interacting with long-running processes, code agents, or development environments.

## Goals

- Attach to existing tmux sessions from a web browser
- Stream terminal output in real-time via LiveView WebSocket
- Send keyboard input back to the tmux pane
- Support multiple simultaneous sessions/panes
- Minimal setup — run alongside existing tmux workflows

## Architecture

### High-Level Components

```
Browser (LiveView client)
    |
    | WebSocket (Phoenix Channel / LiveView)
    |
Phoenix Application
    |
    |-- LiveView: TerminalLive
    |       Renders terminal output, handles keyboard input
    |
    |-- TmuxManager (GenServer)
    |       Discovers sessions, manages pane attachments
    |
    |-- PaneStream (GenServer, one per attached pane)
    |       Streams output via `tmux capture-pane` polling
    |       Sends keystrokes via `tmux send-keys`
    |
tmux server (host)
```

### Key Modules

#### `RemoteCodeAgents.TmuxManager`
- **Responsibility**: Discover and list available tmux sessions, windows, and panes
- **Interface**:
  - `list_sessions/0` — returns `[%Session{name, windows, created, attached?}]`
  - `list_panes/1` — returns panes for a given session/window
  - `session_exists?/1` — check if a session is still alive
- **Implementation**: Calls `tmux list-sessions`, `tmux list-windows`, `tmux list-panes` with format strings and parses output

#### `RemoteCodeAgents.PaneStream`
- **Responsibility**: Bidirectional bridge between a tmux pane and a LiveView process
- **Interface**:
  - `start_link/1` — starts streaming for a `{session, window, pane}` target
  - `send_keys/2` — sends input to the pane via `tmux send-keys`
  - `capture/1` — captures current pane content via `tmux capture-pane -p`
- **Implementation**:
  - Polls `tmux capture-pane -p -t {target}` on a configurable interval (default ~100ms)
  - Diffs output to avoid sending unchanged frames
  - Broadcasts new content to subscribed LiveView processes via PubSub
- **Supervision**: Dynamic supervisor — one PaneStream per actively viewed pane, shut down when no viewers remain

#### `RemoteCodeAgents.Terminal.Parser`
- **Responsibility**: Parse ANSI escape sequences from tmux output and convert to HTML for rendering
- **Approach options**:
  1. Use a JavaScript terminal emulator (xterm.js) on the client — send raw bytes, let JS handle rendering
  2. Server-side ANSI-to-HTML conversion — parse escape codes in Elixir, send HTML fragments via LiveView
- **Recommendation**: Option 1 (xterm.js) — it handles scrollback, cursor positioning, colors, and resize correctly. LiveView sends raw terminal data as binary payloads via a hook.

### LiveView Pages

#### `RemoteCodeAgentsWeb.SessionListLive`
- Route: `/`
- Lists all tmux sessions and their windows/panes
- Auto-refreshes via periodic `handle_info`
- Click a pane to open the terminal view

#### `RemoteCodeAgentsWeb.TerminalLive`
- Route: `/sessions/:session/:window/:pane`
- Renders an xterm.js terminal in a LiveView container
- LiveView Hook (`TerminalHook`):
  - Initializes xterm.js `Terminal` instance on mount
  - Receives binary terminal data from server via `pushEvent` and writes to xterm.js
  - Captures keyboard input and sends back to server via `pushEvent`
- Server side:
  - Subscribes to PaneStream PubSub topic for the target pane
  - On receiving new output, pushes to client
  - On receiving keystrokes from client, calls `PaneStream.send_keys/2`

## Data Flow

### Terminal Output (tmux -> browser)

1. `PaneStream` polls `tmux capture-pane -p -e -t {target}` (with escape sequences)
2. Diffs against previous capture
3. Broadcasts diff/full frame to PubSub topic `"pane:#{target}"`
4. `TerminalLive` receives via `handle_info`, pushes binary to client
5. `TerminalHook` writes data to xterm.js instance

### Keyboard Input (browser -> tmux)

1. xterm.js `onData` callback fires in `TerminalHook`
2. Hook calls `pushEvent("key_input", %{data: ...})`
3. `TerminalLive.handle_event("key_input", ...)` calls `PaneStream.send_keys/2`
4. `PaneStream` executes `tmux send-keys -t {target} -l ...` (literal mode)

### Pane Resize

1. xterm.js reports resize via `onResize` in hook
2. Hook sends `pushEvent("resize", %{cols: c, rows: r})`
3. Server calls `tmux resize-pane -t {target} -x {cols} -y {rows}`

## Technology Choices

| Component          | Choice              | Rationale                                              |
|--------------------|---------------------|--------------------------------------------------------|
| Language           | Elixir              | User preference; excellent for concurrent I/O          |
| Web framework      | Phoenix 1.7+        | Standard Elixir web framework                          |
| Real-time UI       | Phoenix LiveView    | WebSocket-based, no separate API needed                |
| Terminal rendering | xterm.js            | Battle-tested terminal emulator; handles ANSI, cursor  |
| Terminal backend   | tmux CLI            | No library bindings needed; shell out to `tmux`        |
| Process management | DynamicSupervisor   | One child per active pane stream                       |
| Pub/Sub            | Phoenix.PubSub      | Built-in, lightweight; connects PaneStreams to LiveViews|

## Project Structure

```
remote_code_agents/
  lib/
    remote_code_agents/
      application.ex          # Supervision tree
      tmux_manager.ex          # Session/pane discovery
      pane_stream.ex           # Per-pane output streaming GenServer
      pane_stream_supervisor.ex # DynamicSupervisor for PaneStreams
    remote_code_agents_web/
      live/
        session_list_live.ex   # Session listing page
        terminal_live.ex       # Terminal view page
      components/
        layouts.ex             # App shell layout
  assets/
    js/
      hooks/
        terminal_hook.js       # xterm.js integration hook
      app.js
    vendor/
      (xterm.js via npm)
  config/
    config.exs
    dev.exs
    runtime.exs
  mix.exs
```

## Configuration

```elixir
# config/config.exs
config :remote_code_agents,
  # Polling interval for tmux capture-pane (ms)
  capture_interval: 100,
  # Default terminal dimensions
  default_cols: 120,
  default_rows: 40
```

## Security Considerations

- **Authentication**: This application gives full terminal access. Must be protected:
  - Phase 1: Bind to `127.0.0.1` only (local access)
  - Phase 2: Add basic auth or token-based auth for remote access
- **Input sanitization**: `send-keys` with `-l` (literal) flag prevents tmux command injection, but the user is intentionally sending arbitrary commands to a shell — access control is the real boundary
- **HTTPS**: Required if exposed beyond localhost; configure via Phoenix endpoint or reverse proxy

## Open Questions

1. **Capture strategy**: Polling `capture-pane` vs. using `tmux pipe-pane` to stream output to a FIFO/pipe? Pipe-pane would be more efficient but adds complexity.
2. **Scrollback**: Should we capture scrollback history on initial attach? `capture-pane -p -S -` captures full scrollback.
3. **Multiple viewers**: Should multiple browser tabs viewing the same pane share one PaneStream, or each get their own? (Shared is more efficient — use PubSub subscriber count to manage lifecycle.)
4. **Session creation**: Should the app support creating new tmux sessions, or only attaching to existing ones?
5. **Copy/paste**: xterm.js supports selection — should we add clipboard integration?

## MVP Scope

For the first working version:

1. List tmux sessions and panes on the index page
2. Click a pane to open a terminal view with xterm.js
3. Stream output from the pane to the browser
4. Send keyboard input from the browser to the pane
5. Bind to localhost only (no auth needed)

Non-MVP (future):
- Authentication for remote access
- Session creation/management
- Pane resize sync
- Multiple viewer support
- Scrollback capture on attach
