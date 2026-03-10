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
    |-- TmuxManager (stateless module)
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
    |-- Config (GenServer)
    |       Reads/watches YAML config file, serves config to LiveViews
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
- **Registration**: Dual-key via `Registry`:
    1. `{:pane, target}` — primary key, set via GenServer `name:` option at `start_link`. Used by `subscribe/1` to find an existing PaneStream for a given target. Lookup: `Registry.lookup(RemoteCodeAgents.PaneRegistry, {:pane, target})`.
    2. `{:pane_id, pane_id}` — secondary key, registered manually via `Registry.register/3` during init after resolving the stable `pane_id`. Used to detect stale PaneStreams after a session/window rename (see "Stale PaneStream detection" in Lifecycle below).
- **State**:
  - `target` — the `session:window.pane` identifier (human-readable, used for Registry key, PubSub topic, display, and URL routing)
  - `pane_id` — tmux's stable pane identifier (e.g., `%0`), resolved during startup via `tmux display-message -p -t {target} '#{pane_id}'`. Used for `send-keys` and pane existence checks. Stable across session/window renames.
  - `pipe_port` — Elixir Port running `cat` on the FIFO
  - `viewers` — `MapSet` of subscriber PIDs (monitored)
  - `buffer` — ring buffer (`RemoteCodeAgents.RingBuffer`, a fixed-capacity circular binary buffer; API: `new(capacity)`, `append(buffer, binary)` — overwrites oldest data when full, `read(buffer)` — returns a single contiguous binary by concatenating the two halves, `size(buffer)` — current byte count) of all output (scrollback + streaming). Sized dynamically based on the pane's tmux `history-limit` and width (see Buffer Sizing below). All viewers — first or late — receive the same history from this buffer. `RingBuffer.read/1` returns a single contiguous binary by concatenating the two halves of the circular buffer internally. Note: this allocates a copy up to `ring_buffer_max_size` (default 8MB) per call. This is acceptable for the expected viewer count (single-user tool with a handful of concurrent tabs); if many viewers connect simultaneously to a large-buffer pane, the transient memory spike from concurrent `read/1` copies is bounded by `concurrent_viewers × ring_buffer_max_size` (since subscribes serialize through the GenServer, in practice only one copy exists at a time — the bound applies to the aggregate of copies held by viewers that haven't yet consumed them). Because `subscribe/1` makes a `GenServer.call` that triggers `RingBuffer.read/1`, concurrent subscribes to the same pane serialize through the GenServer — during high-throughput output, each subscribe briefly blocks output processing. This is acceptable for the expected concurrency (a few tabs); the call returns quickly since `read/1` is a memory copy, not I/O.
  - `status` — `:starting | :streaming | :dead | :shutting_down`. Transitions: `:starting` (init, before pipe-pane attach) → `:streaming` (after startup sequence completes successfully, and on successful pipeline recovery) → `:dead` (Port EOF with status 0, or recovery failure/exhaustion) or `:shutting_down` (grace period expired, deliberate shutdown). `:starting` prevents `send_keys` calls during the startup window (treated same as `:dead` — returns `{:error, :not_ready}`).
  - `grace_timer_ref` — reference from `Process.send_after/3` for the grace period timer, or `nil`. Used by `Process.cancel_timer/1` when a new viewer subscribes during the grace period.
  - `port_recovery` — `%{attempts: non_neg_integer, window_start: integer | nil}` tracking pipeline recovery attempts. Reset when 60 seconds elapse since `window_start` with no further crashes. Max 3 attempts per window.
- **Interface**:
  - `start_link/1` — starts streaming for a target pane
  - `subscribe/1` — **module function** (not a GenServer call) called by a viewer process. Uses `self()` to identify the caller. The function:
      1. Subscribes the caller to the PubSub topic `"pane:#{target}"` — this happens in the caller's process context (since `Phoenix.PubSub.subscribe/2` always subscribes `self()`), ensuring PubSub messages are delivered directly to the viewer (e.g., the LiveView), not to the GenServer.
      2. Checks Registry for an existing PaneStream; if not found, starts one under DynamicSupervisor via `start_link/1`. If `start_link/1` returns `{:error, {:already_started, pid}}` (race with another concurrent `subscribe/1` call), uses the existing PID.
      3. Makes a `GenServer.call` to the (now-running) PaneStream to register the viewer: monitors the caller PID and returns `{:ok, history, pane_stream_pid}` where `history` is the current ring buffer contents (a single contiguous binary from `RingBuffer.read/1`) and `pane_stream_pid` is the PaneStream's PID (so the caller can monitor it for crash recovery).
    The PubSub subscription (step 1) happens before history is returned (step 3), guaranteeing no messages are lost between receiving history and streaming — any messages arriving during step 2-3 queue in the caller's mailbox and are processed after mount completes. Note: subscribing to PubSub before the PaneStream exists (step 1 before step 2) is safe because no process is publishing to the topic yet — the PaneStream won't publish until its `init/1` completes and output arrives. Returns `{:error, :pane_not_found}` if the tmux pane does not exist (detected during startup when `pipe-pane` fails), or `{:error, :max_pane_streams}` if the DynamicSupervisor's child limit has been reached. On error, the function unsubscribes from the PubSub topic before returning to avoid a leaked subscription.
  - `unsubscribe/1` — called by a viewer process. Uses `self()` to identify the caller. Removes the caller from the viewer set and demonitors the PID. Idempotent — safe to call multiple times or after the monitor has already fired (e.g., `terminate/2` calls `unsubscribe` but the DOWN message may also arrive). If no viewers remain after removal, starts the grace period timer.
  - `send_keys/2` — sends input (as a binary) to the pane via `tmux send-keys -H -t {pane_id}` (using the stable `pane_id`, not the human-readable `target`). Each byte of the binary is converted to its two-character hex representation. If status is `:dead`, skips the call and returns `{:error, :pane_dead}`. If the `send-keys` command fails (e.g., pane died between checks), logs a warning and returns `:ok` — pane death notification will follow shortly via the Port EOF flow.
- **Lifecycle**:
  - Monitors all viewer PIDs — auto-unsubscribes on viewer crash/disconnect
  - On last viewer unsubscribe: starts a configurable grace period timer (default 5s) via `Process.send_after(self(), :grace_period_expired, ...)`. If a new viewer subscribes within the grace period, cancel the timer via `Process.cancel_timer/1`. When the `:grace_period_expired` message arrives in `handle_info`, re-check `MapSet.size(viewers) == 0` before proceeding with shutdown — this eliminates the race between a late subscribe and the timer firing. **Why this is safe**: Even if `Process.cancel_timer/1` returns `false` (the `:grace_period_expired` message is already in the mailbox), the GenServer processes messages sequentially. The subscribe call (which adds the viewer to the MapSet) is a `GenServer.call` that will be processed before or after the timer message. If the subscribe is processed first, the viewer is in the MapSet and the re-check prevents shutdown. If the timer fires first, the re-check sees zero viewers and shuts down — but the subscribe call will then start a fresh PaneStream via the get-or-start logic. Note: in this case, the new PaneStream runs the full startup sequence (including scrollback re-capture), which is correct — the ring buffer from the old PaneStream is gone, so fresh history must be loaded. This is a brief reconnect, not data loss.
  - On `{:superseded, new_target}` cast (another PaneStream claimed this `pane_id` under a new target after a rename): detach `pipe-pane`, clean up FIFO, broadcast `{:pane_superseded, target, new_target}` to viewers via PubSub (viewers can use `new_target` to redirect), then terminate normally. Viewers that don't handle `:pane_superseded` will still recover via the `:DOWN` monitor on the PaneStream PID. Log at `info` level: "PaneStream #{target} superseded by #{new_target} (pane #{pane_id} was renamed)".
  - On Port exit with status 0 (normal EOF — pane died, pipe-pane closed the FIFO): cancel any active grace period timer, set status to `:dead`, broadcast `{:pane_dead, target}` to all viewers via PubSub, clean up FIFO, then terminate. Log at `info` level.
  - On Port exit with non-zero status (`cat` crashed — e.g., OOM-killed, signal): the tmux pane may still be alive. The PaneStream attempts pipeline recovery:
      1. Check if the pane still exists: `tmux display-message -p -t {pane_id} '#{pane_id}'` (using the stored stable pane_id).
      2. If the pane is alive, re-run the pipeline setup: remove stale FIFO, create new FIFO, start new `cat` Port, re-attach `pipe-pane` (using `pane_id`). Do NOT re-capture scrollback — the ring buffer already has history and streaming output, and re-capturing would introduce duplication. Set status back to `:streaming`. Log at `warning` level: "Port exited with status {n}, pane still alive — restarting pipeline".
      3. If recovery fails (pane gone, FIFO error, pipe-pane fails), fall through to the normal death path: set status to `:dead`, broadcast `{:pane_dead, target}`, clean up, terminate. Log at `error` level.
      4. Limit recovery attempts to 3 within a 60-second window to prevent infinite restart loops (e.g., if `cat` is repeatedly killed). After exhausting retries, follow the death path. The retry counter resets after 60 seconds of stable streaming.
    This distinction is safe because exit status 0 from `cat` reliably indicates EOF (the write end of the FIFO was closed, meaning pipe-pane detached because the pane died). Non-zero indicates an abnormal `cat` termination unrelated to pane lifecycle.

#### `RemoteCodeAgents.Tmux.CommandRunner`
- **Responsibility**: Execute tmux CLI commands and return parsed output
- **Interface**:
  - `run/1` — takes a list of argument strings (e.g., `["list-sessions", "-F", "#{session_name}"]`), prepends the tmux binary path, executes via `System.cmd/3`. Returns `{:ok, output}` or `{:error, reason}`.
  - `run!/1` — same but raises on error.
- **Rationale**: Single point of contact with the tmux CLI. Makes it easy to mock in tests and add logging/rate-limiting later.
- **Implementation**: Uses `System.cmd/3` with stderr capture. Validates that `tmux` is available on startup.
- **Minimum tmux version**: 2.6+ required (`send-keys -H` was added in 2.6). `CommandRunner` checks the tmux version once on application startup (via `tmux -V`), caches the result in a persistent term (`:persistent_term.put({__MODULE__, :version_checked}, true)`), and logs an error if below 2.6. Subsequent calls skip the check.

### tmux pipe-pane Strategy

**Why pipe-pane over capture-pane polling:**
- `capture-pane` polling at 100ms means up to 100ms latency per frame, wastes CPU diffing unchanged screens, and scales poorly with many panes
- `pipe-pane` gives true streaming — output arrives as soon as tmux processes it, with zero polling overhead
- Critical for high-latency connections: every millisecond of unnecessary server-side delay compounds with network latency

**Implementation — startup sequence:**

```
PaneStream startup (order matters):
  0. Resolve pane_id: tmux display-message -p -t {target} '#{pane_id}'
     — Returns the stable pane identifier (e.g., "%0"). Stored in state
       as `pane_id` and used for all subsequent tmux commands that target
       this pane (send-keys, has-session, display-message). If this fails,

  0b. Register pane_id and detect stale PaneStreams:
     — Call `Registry.register(PaneRegistry, {:pane_id, pane_id}, nil)`.
     — If it returns `{:ok, _}`, no collision — proceed normally.
     — If it returns `{:error, {:already_registered, old_pid}}`, a stale
       PaneStream exists for this pane under an old target (session/window
       was renamed). Send `GenServer.cast(old_pid, {:superseded, target})`
       to tell it to shut down, then retry the registration after a brief
       `Process.sleep(100)` (the old process needs time to terminate and
       release the key). If the retry also fails, log a warning and proceed
       without the secondary registration — the stale one will still
       eventually clean up via grace period.


       the pane does not exist — return {:error, :pane_not_found}.
  1. Detach any existing pipe-pane on the target: tmux pipe-pane -t {pane_id}
     — No-op if nothing is attached. Prevents conflict with a stale pipe-pane
       left by a previous crash, or an externally-attached pipe.
  2. Remove stale FIFO if present: File.rm({fifo_path}) (ignore errors)
  3. Create FIFO directory if needed: mkdir -p {fifo_dir}
  4. Create named pipe: mkfifo -m 0600 {fifo_dir}/pane-{percent_encoded_target}.fifo
     — The `-m 0600` flag sets owner-only read/write at creation time,
       before any other process can open the FIFO
  5. Start Elixir Port: open_port({:spawn, "cat {fifo_path}"}, [:binary, :stream, :exit_status])
     — `cat` blocks on FIFO open until a writer connects, which is fine
       because it runs in a separate OS process and won't block the GenServer
  6. Attach pipe: tmux pipe-pane -t {pane_id} -o 'cat >> {fifo_path}'
     — `-o` flag captures output only (the stdout side of the pty), preventing
       the input side from being captured and doubled
     — This opens the write end of the FIFO, unblocking the `cat` reader
  7. Query buffer size: determine ring buffer capacity (see Buffer Sizing below)
  8. Capture initial scrollback: tmux capture-pane -p -e -S -{max_lines} -t {pane_id}
     — `max_lines` is computed as `ring_buffer_capacity / pane_width` (from step 7),
       limiting the capture to approximately what the ring buffer can hold. This avoids
       pulling the full tmux history (potentially tens of MB for large history-limit
       values) only to discard most of it when writing into the capped ring buffer.
     — `-p` outputs to stdout; `-e` preserves ANSI escape sequences. Note:
       this output includes a trailing newline per line, which may differ
       slightly from the raw pty stream delivered by pipe-pane. xterm.js
       handles both formats correctly — cursor positioning is re-derived
       from the escape sequences, not from line boundaries.
     — Done AFTER pipe-pane attach so no output is lost between steps
     — Any output generated between steps 6 and 8 will appear in both
       the pipe stream and the scrollback capture. This overlap is
       accepted — see Scrollback Overlap below.
  9. Write scrollback into ring buffer as initial content
     — From this point on, the ring buffer is the single source of history
     — Streaming output from the pipe appends to the same buffer
     — Old content naturally rolls off as the buffer fills
```

**Startup sequence rationale**: The key insight is that `cat` on a FIFO blocks at the OS level until a writer opens the pipe, but since it's a Port (separate OS process), it doesn't block the Elixir GenServer. The GenServer can proceed to call `pipe-pane` which opens the write end, unblocking `cat`. This avoids the FIFO deadlock without needing `O_NONBLOCK` or `O_RDWR` hacks.

Scrollback is captured *after* pipe-pane is attached (step 8 after step 6). This means there's a brief window where output appears in both the pipe stream and the scrollback capture. This overlap is accepted rather than deduplicated — see below.

The scrollback is written into the ring buffer as its initial content, making the ring buffer the single source of history for all viewers. As new output streams in, old scrollback naturally rolls off the end of the buffer. This eliminates the gap problem for late-joining viewers — every subscriber receives one contiguous block of history from the ring buffer.

**Scrollback Overlap (accepted, not deduplicated)**:

Between step 6 (pipe-pane attach) and step 8 (capture-pane), any output the pane produces will appear in both the pipe stream and the scrollback capture. Byte-level deduplication is not feasible because `capture-pane -p -e` and the raw pipe-pane stream use fundamentally different formats: capture-pane produces a rendered screen dump (newline-delimited, padded lines, normalized SGR sequences) while pipe-pane delivers raw terminal protocol bytes (cursor movement via escape sequences, no line delimiters). These cannot be reliably compared without full terminal emulation on the server.

Instead, the full scrollback capture is written into the ring buffer, and any overlapping pipe data that arrived during steps 5-7 is appended after it. The impact is minimal:

- **Common case (pane idle)**: No output during the overlap window. Zero duplication.
- **Line-oriented output**: A few duplicated lines in the scrollback region. These scroll away quickly and do not affect interactive use.
- **Full-screen applications** (vim, htop, top): Duplication is invisible — xterm.js overwrites the same screen cells via cursor positioning escape sequences.
- **Overlap is bounded by time, not by scrollback size**: Only output produced during the few milliseconds between steps 6 and 8 is duplicated — not the entire scrollback.

**Shutdown sequence:**

```
PaneStream shutdown:
  1. Set status to :shutting_down (so handle_info ignores the Port exit that follows)
  2. Detach pipe: tmux pipe-pane -t {pane_id}   (no command argument = detach)
  3. Close the Port (sends SIGTERM to cat, which closes the FIFO read end)
  4. Remove the FIFO: File.rm({fifo_path})
```

The `:shutting_down` status prevents the Port exit (triggered by step 2 closing the FIFO write end) from being misinterpreted as pane death. The `handle_info` for `{port, {:exit_status, _}}` checks status and ignores the event if already `:shutting_down`.

**PaneStream crash recovery (primary cleanup mechanism)**: There are two distinct recovery paths:
1. **Port crash (cat dies, GenServer alive)**: Handled *inside* the running GenServer via `handle_info({port, {:exit_status, n}})` — the GenServer checks if the pane is still alive and restarts the pipeline (FIFO + Port + pipe-pane) without restarting the GenServer process itself. See "Port exit with non-zero status" above. Viewers are unaware.
2. **GenServer crash (unhandled exception)**: The supervisor restarts the GenServer process (PaneStream children use `restart: :transient`, so only abnormal exits trigger restart). The `init/1` callback runs the full startup sequence above — steps 0-9 — which inherently handles cleanup: step 1 detaches any stale pipe-pane, step 2 removes any stale FIFO. Viewers detect the crash via their monitor `:DOWN` message and re-subscribe to the new PaneStream (see TerminalLive `:DOWN` handler). This per-PaneStream cleanup is the primary safety net — it runs on every start, whether after a crash, a restart, or first boot.

**tmux server restart / mass pane death**: If the tmux server is killed or restarted, all PaneStream Ports receive EOF simultaneously. Each PaneStream independently follows its normal death path (set `:dead`, broadcast `:pane_dead`, terminate normally). Since `restart: :transient` does not restart normal exits, the DynamicSupervisor does not restart any of them — there is no thundering herd of restarts. Each TerminalLive viewer receives its own `:pane_dead` message and shows "Session ended." SessionListLive's polling (every 3s) will naturally show an empty session list, reflecting the correct state. No special mass-death detection is needed.

**Application startup cleanup (defense-in-depth)**: In `Application.start/2`, before the supervision tree starts: (1) detach all stale pipe-pane attachments by iterating `tmux list-panes -a -F '#{pane_id}'` and running `tmux pipe-pane -t {pane_id}` on each (this is a no-op for panes that don't have pipe-pane attached); (2) clear the FIFO directory (`File.rm_rf(fifo_dir)` then `File.mkdir_p(fifo_dir)`). This catches both orphaned pipe-pane attachments and stale FIFOs left by a hard kill (SIGKILL) of the entire application, where no cleanup callbacks run. It only takes effect on the *next* application boot.

**FIFO naming and shell safety**: Target strings like `mysession:0.1` are sanitized for filesystem use using percent-encoding: `:` becomes `%3A` and `.` becomes `%2E`, giving FIFO names like `pane-mysession%3A0%2E1.fifo`. This is collision-free because `%` cannot appear in tmux session names (which match `^[a-zA-Z0-9_-]+$`) or in the window/pane numeric indices. **Shell injection safety**: The resulting FIFO paths contain only `[a-zA-Z0-9_%.-/]` characters, making them safe for interpolation into the `open_port({:spawn, "cat {fifo_path}"})` shell string (step 4) and the `pipe-pane` command's single-quoted argument (step 5). This safety is guaranteed by the composition of: (1) session name validation (`^[a-zA-Z0-9_-]+$`), (2) window/pane indices being numeric, and (3) percent-encoding replacing `:` and `.` with `%XX` sequences. No shell metacharacters can appear in the path.

### Buffer Sizing

The ring buffer is the single source of history for all viewers. Its size is computed dynamically per pane at PaneStream startup:

1. Query the pane's effective `history-limit`: `tmux show-option -wv -t {target} history-limit` (falls back to `tmux show-option -gv history-limit` for the global default)
2. Query the pane width: `tmux list-panes -t {target} -F '#{pane_width}'`
3. Compute: `history_limit × pane_width` bytes (one byte per cell is a rough estimate; ANSI escape sequences from `capture-pane -e` and multi-byte UTF-8 characters add overhead that can exceed this, but most lines aren't full-width, so it roughly balances out)
4. Clamp the result between `ring_buffer_min_size` (default 512KB) and `ring_buffer_max_size` (default 8MB)
5. If either tmux query fails, use `ring_buffer_default_size` (default 2MB)
6. **Memory pressure check**: Before allocating, check `:erlang.memory(:total)` against `memory_high_watermark` (default 768MB). If BEAM memory exceeds the watermark, use `ring_buffer_min_size` instead of the computed size and log a warning: "Memory pressure detected ({current}MB used, watermark {watermark}MB) — using minimum ring buffer size for pane {target}". Existing PaneStreams are not affected — only new ones are constrained. This provides graceful degradation without requiring a central memory coordinator.

**Examples**:
- Default tmux (2000 lines × 120 cols) = 240KB → clamped to 512KB (floor)
- Heavy user (50000 lines × 200 cols) = 10MB → clamped to 8MB (ceiling)
- Typical dev (10000 lines × 120 cols) = 1.2MB → used as-is

**Aggregate memory budget**: With `max_pane_streams: 100` and `ring_buffer_max_size: 8MB`, the theoretical worst case is 800MB. In practice, most panes use 1-2MB buffers, so typical usage with 10-20 active panes is 10-40MB. The `memory_high_watermark` check ensures new panes degrade to minimum buffers before the application hits system memory limits.

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

**Why hex mode for tmux**: Simpler than branching between `-l` for printable chars and raw mode for control chars. No escaping edge cases. Works uniformly for all input including Unicode (UTF-8 bytes as hex). Multi-byte UTF-8 sequences (e.g., emoji like 😀 = 4 bytes `F0 9F 98 80`) are sent as individual hex bytes and tmux reassembles them correctly. This should have an explicit integration test.

**Performance**: For typical interactive use, `send-keys -H` with a handful of hex bytes per keystroke is negligible overhead. For bulk paste operations, bytes are chunked into groups of up to 65,536 bytes (well under Linux's default `ARG_MAX` of ~2MB, accounting for hex encoding doubling the size and argument overhead) and sent as sequential `send-keys -H` calls. Note: chunked sends execute synchronously within the GenServer, briefly blocking output processing during large pastes. This is acceptable for a single-user tool — large pastes are rare, each `System.cmd` call completes in milliseconds, and output resumes immediately after. If needed, chunked sends could be offloaded to a Task without changing the public interface.

**Input size limit**: `TerminalLive.handle_event("key_input", ...)` validates that the decoded payload does not exceed 128KB. Payloads exceeding this limit are logged and dropped. This prevents a buggy or malicious client from sending arbitrarily large input in a single event. The 128KB limit is above the chunking threshold for paste (64KB — see above) with headroom for base64 overhead (~33%), while keeping the bound tight enough to be meaningful.

**Input rate limiting**: The client-side input batching (every 16ms, described in Bandwidth Optimization) provides natural throttling. On the server side, `PaneStream.send_keys/2` does not rate-limit — each call executes a `tmux send-keys` command immediately. If a misbehaving client floods `send_keys` calls, the tmux process is the bottleneck (each `send-keys` is a short-lived fork). This is acceptable for a single-user tool; if needed, a per-viewer token bucket could be added in `PaneStream`.

### LiveView Pages

#### `RemoteCodeAgentsWeb.SessionListLive`
- Route: `/`
- Lists all active tmux sessions with their windows and panes
- "New Session" button/form — creates a new tmux session (name input with validation, optional starting command)
- **Session list updates** use a hybrid approach:
  - **Instant**: Subscribes to PubSub topic `"sessions"` on mount. `TmuxManager.create_session/1` and `kill_session/1` broadcast `{:sessions_changed}` on this topic after mutating state, so the session list updates immediately for app-driven changes.
  - **Polling fallback**: `Process.send_after(self(), :refresh_sessions, interval)` in `handle_info` catches external changes (sessions created/killed from the terminal). Default interval is 3 seconds. This is a lightweight **server-local** call (`tmux list-sessions` reads tmux's in-memory state) — it does not generate network traffic unless the session list actually changed (LiveView only pushes diffs). The interval is configurable via `config :remote_code_agents, session_poll_interval: 3_000`.
- Click a pane to navigate to the terminal view via `push_navigate`
- Shows pane dimensions and running command (from `tmux list-panes -F` format)
- Mobile layout: full-width card list, large touch targets
- Empty state: friendly message when no tmux sessions exist, with prominent "Create Session" CTA

#### `RemoteCodeAgentsWeb.TerminalLive`
- Route: `/sessions/:session/:window/:pane`
- Full-viewport xterm.js terminal
- **LiveView Hook (`TerminalHook`)**:
  - `mounted()`: Creates xterm.js `Terminal` + `FitAddon`, opens terminal in container div, calls `FitAddon.fit()`, sends initial `resize` event to server
  - `onData`: xterm.js keyboard input → UTF-8 encode via `TextEncoder` → base64 encode → `this.pushEvent("key_input", {data: base64String})`. `onData` emits JavaScript strings which `TextEncoder` converts to UTF-8 bytes. This is sufficient for all terminal input: printable characters, control codes, and escape sequences are all within the BMP (U+0000–U+FFFF). Characters above U+FFFF (e.g., emoji) are not emitted by `onData` — they arrive via paste, which also goes through `TextEncoder` and encodes correctly as multi-byte UTF-8. `onBinary` is not needed.
  - `onResize`: debounced (300ms) → `this.pushEvent("resize", {cols, rows})`
  - `this.handleEvent("output", ({data}) => { const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0)); term.write(bytes); })` — streaming terminal output
  - `this.handleEvent("history", ({data}) => { const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0)); term.write(bytes); })` — initial scrollback on attach (before streaming begins)
  - `this.handleEvent("reconnected", ({data}) => { term.reset(); const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0)); term.write(bytes); })` — seamless refresh after PaneStream crash recovery
  - `this.handleEvent("pane_dead", () => { /* display overlay message "Session ended", offer link back to session list */ })` — pane death notification
  - Clipboard: `onSelectionChange` → auto-copy to clipboard; paste handler intercepts Ctrl+Shift+V / toolbar button
  - `destroyed()`: Clean up xterm.js instance
- **Server side** (`mount/3`):
  - Constructs target from URL params: `"#{session}:#{window}.#{pane}"` (where session, window, pane are from the route `/sessions/:session/:window/:pane` — window and pane are integer indices)
  - Calls `PaneStream.subscribe(target)` — gets `{:ok, history, pane_stream_pid}` (PubSub subscription is handled internally by `subscribe/1`, so no messages are lost between receiving history and streaming) or `{:error, :pane_not_found}` (show error UI)
  - Monitors the returned `pane_stream_pid` via `Process.monitor/1` and stores the monitor ref in assigns
  - Pushes history to client via `push_event(socket, "history", %{data: ...})`
  - `handle_info({:pane_output, data})` → `push_event(socket, "output", %{data: data})`
  - `handle_info({:pane_dead, _target})` → `push_event(socket, "pane_dead", %{})`
  - `handle_info({:DOWN, ref, :process, _pid, _reason})` — PaneStream crashed. The viewer demonitors the old ref, then calls `PaneStream.subscribe(target)` again (which starts or finds the restarted PaneStream). If successful, pushes fresh history to the client (xterm.js `term.reset()` + `term.write(history)` via a `"reconnected"` push event) and monitors the new PID. If the pane no longer exists, transitions to the pane-dead UI. This recovery is transparent to the user — output briefly pauses, then the terminal refreshes with full history.
  - `handle_event("key_input", %{"data" => b64})` → `Base.decode64/1` with error handling (invalid base64 is logged and ignored, not crashed on) → `PaneStream.send_keys(target, bytes)`
  - `handle_event("resize", %{"cols" => c, "rows" => r})` → Phase 1: stored in assigns for future use but no `tmux resize-pane` call is made (resize is disabled). See Resize Conflicts below for the future strategy.
  - `terminate/2`: calls `PaneStream.unsubscribe(target)`. Note: `terminate/2` is best-effort — it does not run on node crash or hard network timeout. The real safety net is PaneStream's monitor on the viewer PID, which fires a `:DOWN` message and triggers auto-unsubscribe regardless of how the viewer process exits.
  - **LiveView crash recovery**: If the LiveView process itself crashes (or the WebSocket disconnects), Phoenix LiveView automatically reconnects and re-mounts. The `mount/3` callback re-runs the full subscribe flow (subscribe to PubSub, get-or-start PaneStream, receive history), making recovery transparent. The old LiveView PID triggers a `:DOWN` in the PaneStream (auto-unsubscribe); the new LiveView PID subscribes fresh. No special handling is needed beyond the standard mount logic.
- Mobile: on-screen virtual keyboard toolbar (see Mobile UI section)
- Back button / navigation header to return to session list

### Phoenix Channel: `TerminalChannel` (Future — Do Not Implement in Phase 1)

For native Android client only. Not used by the web UI. The design below is documented for future reference but is explicitly out of scope for the initial implementation.

- **Topic**: `"terminal:{session}:{window}:{pane}"` — this is the client-facing Channel join topic, not a PubSub topic. The join handler converts it to the internal PaneStream target format (`"terminal:foo:0:1"` → `"foo:0.1"`) and then calls `PaneStream.subscribe/1`, which subscribes to the canonical PubSub topic `"pane:foo:0.1"` — the same topic LiveView uses. The Channel join topic uses colons as delimiters (Phoenix Channel convention), while the internal target uses tmux's native `"session:window.pane"` format.
- **Auth**: Token-based authentication verified in `UserSocket.connect/3` (see Auth Flow — Phoenix Channel below). Channel `join/3` does not re-verify — a valid socket implies a valid user.
- **Join handler**:
  1. Parse topic into target: `"terminal:foo:0:1"` → `"foo:0.1"`.
  2. Call `PaneStream.subscribe/1` — same path as TerminalLive.
  3. Monitor the returned `pane_stream_pid`.
  4. On success, reply `{:ok, %{"history" => base64_binary, "cols" => int, "rows" => int}}` — history is the ring buffer contents, cols/rows are the pane's current dimensions.
  5. On `{:error, :pane_not_found}`, reply `{:error, %{"reason" => "pane_not_found"}}`.
  6. On `{:error, :max_pane_streams}`, reply `{:error, %{"reason" => "max_pane_streams"}}`.
- **Client → Server events**:
  - `"input"` — `%{"data" => base64_binary}` — keyboard input. Decoded, validated (max 128KB, same as LiveView), passed to `PaneStream.send_keys/2`.
  - `"resize"` — `%{"cols" => int, "rows" => int}` — client requests pane resize. Forwarded to `tmux resize-pane`. Validated: cols 1–500, rows 1–200.
- **Server → Client events**:
  - `"output"` — `%{"data" => base64_binary}` — streaming terminal output bytes.
  - `"reconnected"` — `%{"data" => base64_binary}` — full ring buffer after PaneStream crash recovery. Client should clear its terminal and re-render.
  - `"pane_dead"` — `%{}` — pane/session no longer exists. Client should show a disconnected state.
  - `"pane_superseded"` — `%{"new_target" => "new-name:0.1"}` — PaneStream was replaced due to session/window rename. Client can rejoin under the new topic.
  - `"resized"` — `%{"cols" => int, "rows" => int}` — pane was resized by another viewer. Client should resize its terminal view.
- **Leave/disconnect**: `terminate/2` calls `PaneStream.unsubscribe/1`. Same as LiveView, this is best-effort — the real safety net is PaneStream's monitor on the Channel PID, which triggers auto-unsubscribe on crash or network drop. Phoenix Channels reconnect automatically; on reconnect, the client re-joins the topic and receives fresh history.

## Data Flow

### Event Reference

#### LiveView Events (TerminalLive ↔ TerminalHook)

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Client → Server | `"key_input"` | `%{"data" => base64_string}` | Keyboard/paste input. Decoded to UTF-8 bytes, sent via `send-keys -H`. Max 128KB decoded. |
| Client → Server | `"resize"` | `%{"cols" => int, "rows" => int}` | Terminal dimensions after browser resize. Debounced 300ms client-side. Phase 1: stored only, no `resize-pane` call. |
| Client → Server | `"quick_action"` | `%{"id" => string}` | User tapped a quick action button. May trigger confirmation dialog. |
| Client → Server | `"confirm_action"` | `%{}` | User confirmed a quick action that requires confirmation. |
| Client → Server | `"cancel_action"` | `%{}` | User cancelled a quick action confirmation dialog. |
| Server → Client | `"output"` | `%{"data" => base64_string}` | Streaming terminal output bytes. |
| Server → Client | `"history"` | `%{"data" => base64_string}` | Ring buffer contents on initial attach. |
| Server → Client | `"reconnected"` | `%{"data" => base64_string}` | Full buffer after PaneStream crash recovery. Client calls `term.reset()` first. |
| Server → Client | `"pane_dead"` | `%{}` | Pane/session no longer exists. Client shows "Session ended" overlay. |

#### LiveView Events (SettingsLive)

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Client → Server | `"save_action"` | `%{"action" => action_params}` | Create or update a quick action. |
| Client → Server | `"delete_action"` | `%{"id" => string}` | Delete a quick action. |
| Client → Server | `"reorder_actions"` | `%{"ids" => [string]}` | Reorder quick actions by ID list. |

#### PubSub Messages (PaneStream → viewers via `"pane:#{target}"`)

| Message | Payload | Description |
|---------|---------|-------------|
| `{:pane_output, bytes}` | raw binary | Streaming output from tmux pane. |
| `{:pane_dead, target}` | target string | Pane died (Port EOF status 0). |
| `{:pane_superseded, old_target, new_target}` | target strings | PaneStream replaced after session/window rename. |
| `{:pane_resized, cols, rows}` | integers | Pane dimensions changed (future). |

#### PubSub Messages (other topics)

| Topic | Message | Description |
|-------|---------|-------------|
| `"sessions"` | `{:sessions_changed}` | Session created or killed via `TmuxManager`. |
| `"config"` | `{:config_changed, config}` | Config file changed (manual edit or UI save). |

#### Phoenix Channel Events (TerminalChannel — future, Phase 2+)

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Client → Server | `"input"` | `%{"data" => base64_binary}` | Keyboard/touch input. Max 128KB decoded. |
| Client → Server | `"resize"` | `%{"cols" => int, "rows" => int}` | Client requests pane resize. Validated: cols 1–500, rows 1–200. Calls `tmux resize-pane` (unlike Phase 1 LiveView, which stores only). |
| Server → Client | `"output"` | `%{"data" => base64_binary}` | Streaming terminal output. |
| Server → Client | `"reconnected"` | `%{"data" => base64_binary}` | Full buffer after PaneStream crash recovery. Client clears and re-renders. |
| Server → Client | `"pane_dead"` | `%{}` | Pane/session ended. |
| Server → Client | `"pane_superseded"` | `%{"new_target" => string}` | Session/window renamed. Client can rejoin under new topic. |
| Server → Client | `"resized"` | `%{"cols" => int, "rows" => int}` | Pane resized by another viewer. |

**Join reply**: `{:ok, %{"history" => base64_binary, "cols" => int, "rows" => int}}` or `{:error, %{"reason" => string}}`.

### Terminal Output (tmux → browser)

1. tmux writes output → `pipe-pane` writes to FIFO
2. `cat` Port reads from FIFO → Elixir receives `{port, {:data, bytes}}`
3. PaneStream appends to ring buffer, broadcasts `{:pane_output, bytes}` via PubSub topic `"pane:#{target}"`. Each Port message triggers a separate broadcast — no server-side coalescing. This is acceptable because LiveView batches pending `push_event` calls within the same process turn, and xterm.js internally batches `term.write()` calls for rendering. For extreme throughput (e.g., `cat large_file`), the browser is the bottleneck, not the push rate. Coalescing could be added inside PaneStream later without changing any public interfaces if profiling shows PubSub overhead is significant. All messages on this topic are tagged tuples — subscribers must pattern-match on the first element: `:pane_output` for streaming data, `:pane_dead` for pane death, `:pane_resized` for dimension changes (future)
4. `TerminalLive` receives via `handle_info`, calls `push_event(socket, "output", %{data: Base.encode64(bytes)})`
5. `TerminalHook` decodes base64, calls `term.write(bytes)` on xterm.js instance

Note: Both input and output are base64-encoded for LiveView transport since LiveView events are JSON-serialized. Output: server encodes, client decodes. Input: client encodes (via `TextEncoder` + base64), server decodes. For the future Channel implementation, raw binary frames can be used instead.

### Initial Attach (history)

1. Viewer calls `PaneStream.subscribe(target)`
2. If PaneStream not running, starts it under DynamicSupervisor:
   a. Port starts `cat` on FIFO (blocks at OS level, not in GenServer)
   b. `pipe-pane` attached (unblocks `cat`)
   c. `capture-pane` captures scrollback, deduplicates against pipe stream, writes into ring buffer
3. PaneStream returns `{:ok, history, pane_stream_pid}` — ring buffer contents + PID for monitoring
4. TerminalLive monitors `pane_stream_pid` and pushes history to client as `"history"` event
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
3. `cat` Port receives EOF, exits with status 0
4. PaneStream receives `{port, {:exit_status, 0}}` in `handle_info`
5. PaneStream sets status to `:dead`, broadcasts `{:pane_dead, target}` via PubSub, cleans up FIFO, terminates. Logged at `info` level.
6. All TerminalLive viewers receive `handle_info({:pane_dead, _})`, push `"pane_dead"` event to client
7. Client shows "Session ended" overlay with link back to session list

**Port crash (non-zero exit, pane may still be alive)**:

1. `cat` Port is killed externally (OOM, signal) — exits with non-zero status
2. PaneStream receives `{port, {:exit_status, n}}` where `n > 0`
3. PaneStream checks if the tmux pane is still alive
4. If alive: restarts the pipeline (new FIFO, new Port, re-attach pipe-pane), resumes streaming. Viewers are unaware — output briefly pauses then resumes.
5. If dead (or recovery fails, or retry limit exceeded): follows the normal death path above (steps 5-7)
6. PaneStream cleans up FIFO and terminates

### Resize Conflict Resolution

Multiple viewers sharing a pane creates a conflict: resizing the tmux pane affects all viewers.

**Strategy: Last-writer-wins with dimension reporting**

- Any viewer can send a resize event
- Server applies `tmux resize-pane` with the requested dimensions
- Server broadcasts the new dimensions to ALL viewers via PubSub: `{:pane_resized, cols, rows}`
- Other viewers' xterm.js instances are resized to match via `FitAddon.fit()` or `term.resize(cols, rows)`
- On mobile, the terminal adapts to whatever size the pane currently is rather than requesting a resize. Mobile viewers are "passive resizers" — they read the current pane dimensions on connect and fit to them.

**Phase 1 (current scope)**: Resizing is disabled — the pane keeps whatever dimensions it had when created. Viewers fit xterm.js to the existing pane size. The last-writer-wins strategy described above is a future enhancement (see Feature Designs: Pane Resize Sync).

## Bandwidth Optimization

The strategies below are chosen to help on slow/high-latency connections without degrading performance on fast ones. Strategies that would add latency on good connections (aggressive frame-rate throttling, large batch windows, delta/diff encoding on top of the already-incremental pipe-pane stream) are intentionally avoided.

### 1. Streaming, Not Polling

`pipe-pane` delivers only actual output — no wasted bandwidth on unchanged frames. This is the single biggest optimization: zero overhead when the pane is idle, and output arrives as soon as tmux processes it.

### 2. WebSocket `permessage-deflate` Compression

Terminal output (text + ANSI escape codes) compresses very well — typical compression ratios of 3–5× for text-heavy output, 2× for ANSI-colored output.

**Implementation**: Enable in the Phoenix Endpoint config:

```elixir
# config/config.exs
config :remote_code_agents, RemoteCodeAgentsWeb.Endpoint,
  http: [
    websocket_options: [
      compress: true  # enables permessage-deflate
    ]
  ]
```

**Why this is safe on fast connections**: `permessage-deflate` is negotiated per-connection at the WebSocket handshake. The compression library (zlib) adds negligible CPU overhead per message. For very small messages (< ~20 bytes), the compressed output may be larger — cowboy handles this gracefully by sending uncompressed when compression doesn't help. No configuration needed per-connection; the transport handles it.

### 3. Server-Side Output Coalescing

During high-throughput output (e.g., `cat large_file`, build logs), the `cat` Port can fire dozens of `{port, {:data, bytes}}` messages per millisecond. Without coalescing, each triggers a separate PubSub broadcast and WebSocket push, creating overhead in message framing, PubSub dispatch, and WebSocket frames.

**Implementation**: PaneStream uses a short coalescing window in `handle_info`:

1. On first `{port, {:data, bytes}}` when no coalesce timer is active: append bytes to an IO list accumulator, start a timer via `Process.send_after(self(), :flush_output, @coalesce_ms)`.
2. On subsequent Port data while the timer is active: append to the accumulator (IO list cons, no copying).
3. On `:flush_output`: convert the IO list to a binary via `IO.iodata_to_binary/1`, append to ring buffer, broadcast `{:pane_output, coalesced_bytes}` via PubSub, clear the accumulator.
4. If the accumulator exceeds a size threshold (e.g., 32KB) before the timer fires, flush immediately — this prevents unbounded memory growth during extreme throughput.

**Configuration**:

```elixir
# config/config.exs
config :remote_code_agents,
  # Coalescing window (ms) for PaneStream output. 0 = disabled (every Port
  # message triggers an immediate broadcast). Low values (2-5ms) help on
  # slow connections without perceptible delay on fast ones.
  output_coalesce_ms: 3,
  # Flush immediately if accumulated output exceeds this size (bytes)
  output_coalesce_max_bytes: 32_768  # 32 KB
```

**Why this is safe on fast connections**: A 3ms window is below human perception (~13ms visual frame at 75Hz). On a LAN, it means at most 3ms additional latency on the first byte of a burst. During interactive typing (single characters), the Port typically fires one message at a time — the timer fires 3ms later with just that one message, so overhead is one timer per keystroke echo. During high-throughput output, the coalescing is purely beneficial: fewer, larger WebSocket frames are more efficient even on fast connections due to reduced framing overhead.

### 4. Binary Frames on Phoenix Channel (Future)

LiveView requires JSON-serializable payloads, so terminal data is base64-encoded (~33% overhead). The Phoenix Channel for native Android clients can use raw binary payloads instead, eliminating this overhead entirely.

**Implementation**: The Channel `handle_info({:pane_output, bytes})` pushes bytes directly without base64 encoding. The Android client receives raw bytes and passes them to the terminal renderer. This is a pure win — less CPU (no encode/decode) and 33% less bandwidth.

### 5. Client-Side Input Batching

Rapid keystrokes are buffered client-side and sent in batches to reduce round-trip count.

**Implementation in TerminalHook**:

- Buffer keystrokes in a local array.
- Flush every 16ms (one animation frame via `requestAnimationFrame`) or when the buffer exceeds 64 bytes, whichever comes first.
- Concatenate buffered bytes into a single base64 payload and send as one `"key_input"` event.
- During normal interactive typing (~5 chars/sec), most flushes contain a single character — no added latency. During fast paste (handled separately via chunking), this batching is bypassed.

**Why this is safe on fast connections**: 16ms is one frame at 60fps. Interactive typing produces characters far slower than this, so each keystroke is sent individually with at most 16ms delay. The batching only activates during rapid input (e.g., holding a key down), where reducing 30 events to 2 per frame is a pure win.

### 6. Debounced Resize

Client debounces resize events (300ms) to avoid flooding during window resize drag or mobile orientation changes. Only the final dimensions are sent.

### 7. Ring Buffer Cap

History buffer sized dynamically per pane (see Buffer Sizing), clamped between 512KB and 8MB. Provides full scrollback context without excessive transfer on initial attach. Under memory pressure, new panes use the minimum buffer size.

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
| Language           | Elixir >= 1.17      | User preference; excellent for concurrent I/O          |
| Runtime            | OTP >= 27           | Required by modern Phoenix/LiveView                    |
| Web framework      | Phoenix 1.7+        | Standard Elixir web framework                          |
| Real-time UI       | Phoenix LiveView 1.0+  | WebSocket-based, no separate API needed             |
| Terminal rendering | @xterm/xterm 5.x    | Battle-tested terminal emulator; handles ANSI, cursor. Assumes 256-color support — compatible with `tmux-256color`, `screen-256color`, and `xterm-256color` TERM values. See TERM note below. |
| xterm.js addons    | @xterm/addon-fit    | Required — auto-sizes terminal to container            |
|                    | @xterm/addon-web-links | Nice-to-have — makes URLs clickable in terminal     |
| CSS                | Tailwind CSS 3.x    | Ships with Phoenix 1.7+; utility-first, good for responsive |
| Terminal backend   | tmux pipe-pane      | True streaming, lower latency than polling              |
| Process registry   | Elixir Registry     | Built-in, lightweight process lookup by key            |
| Process management | DynamicSupervisor   | One child per active pane stream                       |
| Pub/Sub            | Phoenix.PubSub      | Built-in; connects PaneStreams to viewers               |
| User config (read) | yaml_elixir 2.11+   | YAML parser for quick actions + future settings (needed for Quick Actions feature, not base scope) |
| User config (write)| ymlr 5.0+           | YAML encoder for writing config back to file (needed for Quick Actions feature, not base scope) |
| Mobile terminal    | xterm.js + toolbar  | Works in mobile browsers; virtual key toolbar for special keys |
| Android (future)   | Phoenix Channel     | Direct WebSocket connection; native terminal renderer   |

**TERM environment variable**: xterm.js supports 256-color output and standard ANSI/xterm escape sequences. Tmux sets `TERM` inside its panes based on its `default-terminal` option, which typically defaults to `tmux-256color` or `screen-256color`. Both are compatible with xterm.js. The application does **not** override `TERM` when creating sessions — this is left to the user's tmux configuration. If users experience rendering issues (e.g., missing colors, broken line drawing), they should ensure their tmux config uses a 256-color terminal type: `set -g default-terminal "tmux-256color"`.

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
      ring_buffer.ex                # Circular byte buffer with fixed capacity (new/1, append/2, read/1, size/1)
      pane_stream.ex                # Per-pane streaming GenServer (pipe-pane + FIFO)
      pane_stream_supervisor.ex     # DynamicSupervisor for PaneStreams
      config.ex                     # GenServer: YAML config loader/writer with mtime polling + PubSub
    remote_code_agents_web/
      channels/                     # Future
        terminal_channel.ex         # Raw terminal I/O channel (for native clients)
        user_socket.ex              # Socket configuration
      controllers/                  # REST API (for native clients)
        health_controller.ex        # GET /healthz endpoint
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
  ├── RemoteCodeAgents.Config (GenServer)
  └── RemoteCodeAgentsWeb.Endpoint
```

- `PaneRegistry` starts first — PaneStreams need it for registration
- `PaneStreamSupervisor` starts next — ready to accept PaneStream children. Configured with `max_children: 100` to bound resource usage (FIFOs, ports, memory). If the limit is hit, `subscribe/1` returns `{:error, :max_pane_streams}`. This is configurable via `config :remote_code_agents, max_pane_streams: 100`. PaneStream children use `restart: :transient` — they are restarted on abnormal exit (crash) but not on normal exit (graceful shutdown via grace period or pane death).
- PubSub starts before Config — Config broadcasts via PubSub on config changes
- Config starts before Endpoint — config must be loaded before LiveViews mount
- No TmuxManager in the tree — it's a stateless module, not a process

## Configuration

```elixir
# config/config.exs
config :remote_code_agents,
  # Polling interval (ms) for detecting external session changes in SessionListLive
  session_poll_interval: 3_000,
  # Grace period (ms) before shutting down a PaneStream with zero viewers
  pane_stream_grace_period: 5_000,
  # Ring buffer size bounds (bytes) — actual size is computed dynamically per pane
  # from tmux history-limit × pane width, clamped to these bounds
  ring_buffer_min_size: 524_288,      # 512 KB floor
  ring_buffer_max_size: 8_388_608,    # 8 MB ceiling
  ring_buffer_default_size: 2_097_152, # 2 MB fallback if tmux query fails
  # BEAM memory threshold (bytes) — new PaneStreams use ring_buffer_min_size
  # when :erlang.memory(:total) exceeds this. Existing streams are unaffected.
  memory_high_watermark: 805_306_368,  # 768 MB
  # Maximum concurrent PaneStream processes (bounds FIFOs, ports, memory)
  max_pane_streams: 100,
  # Maximum decoded input payload size (bytes) per key_input event
  input_size_limit: 131_072,  # 128 KB
  # Default terminal dimensions (used when creating new sessions)
  default_cols: 120,
  default_rows: 40,
  # Polling interval (ms) for detecting external config file changes
  config_poll_interval: 2_000,
  # FIFO directory for pipe-pane output
  fifo_dir: "/tmp/remote-code-agents",
  # Path to tmux binary (auto-detected if nil)
  tmux_path: nil,
  # Output coalescing window (ms). Collects rapid Port messages into a single
  # broadcast. 0 = disabled. Low values (2-5ms) reduce overhead on slow
  # connections without perceptible delay on fast ones.
  output_coalesce_ms: 3,
  # Flush coalesced output immediately if accumulated bytes exceed this threshold
  output_coalesce_max_bytes: 32_768  # 32 KB

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

## Health Check Endpoint

`GET /healthz` — unauthenticated, returns a JSON response indicating application and tmux status.

- **Implementation**: `RemoteCodeAgentsWeb.HealthController` — a plain Phoenix controller (not LiveView).
- **Check**: Calls `CommandRunner.run(["list-sessions"])` to verify tmux is reachable. Does not parse the output — success/failure of the command is sufficient.
- **Response**:
  - `200 OK` with `{"status": "ok", "tmux": "ok"}` — app running, tmux reachable
  - `200 OK` with `{"status": "ok", "tmux": "no_server"}` — app running, tmux reachable but no sessions (tmux returns exit 1 with "no server running" — this is not an error, the server starts on demand)
  - `503 Service Unavailable` with `{"status": "error", "tmux": "not_found"}` — tmux binary not installed
- **No auth required**: The endpoint reveals no sensitive information (no session names, no pane content). Safe to expose for reverse proxy and systemd health checks.
- **Route**: Outside the authenticated scope — no token/session needed.

## Security Considerations

- **Authentication**: This application gives full terminal access. Must be protected:
  - Localhost mode (default): Bind to `127.0.0.1` only — no auth required
  - Remote mode: Token-based auth required when binding to `0.0.0.0` (see Authentication & Remote Access in Feature Designs). This is a P1 feature — required for mobile use, the primary motivation.
- **Input handling**: All input sent via `send-keys -H` (hex mode) — bytes are passed directly to tmux with no shell interpretation. The user is intentionally sending arbitrary commands to a shell — access control is the real security boundary.
- **Session name validation**: Enforced at `TmuxManager.create_session/1` — only `^[a-zA-Z0-9_-]+$` accepted. Prevents tmux target format injection.
- **HTTPS**: Required if exposed beyond localhost; configure via Phoenix endpoint or reverse proxy. Also required for Clipboard API access.
- **Channel auth**: `TerminalChannel` (future) must verify auth token on join to prevent unauthorized WebSocket connections from native apps
- **FIFO permissions**: Created via `mkfifo -m 0600` (owner read/write only, set at creation time) to prevent other users on the host from reading terminal output

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

### Session/Window Renamed Externally
- If a user renames a session or window via tmux directly (e.g., `tmux rename-session`), the existing PaneStream continues working because all tmux commands (`send-keys`, `pipe-pane`, `capture-pane`) use the stable `pane_id` (e.g., `%0`), not the human-readable `target` string. Both input and output are unaffected.
- **Display impact**: The PaneStream's `target` field and the URL still reflect the old name. The polling fallback in `SessionListLive` (every 3s) will show the updated session name. The user can navigate to the renamed pane via the new URL.
- **Stale PaneStream detection and cleanup**: When a viewer navigates to the new name, `subscribe/1` starts a new PaneStream under the new target. During init, the new PaneStream resolves `pane_id` and attempts to register `{:pane_id, pane_id}` in the Registry. This collides with the old PaneStream's registration, triggering the supersede flow:
    1. The new PaneStream sends `{:superseded, new_target}` to the old PaneStream.
    2. The old PaneStream detaches its `pipe-pane`, cleans up its FIFO, broadcasts `{:pane_superseded, old_target, new_target}` to its viewers, and terminates normally.
    3. Viewers of the old PaneStream receive the `{:pane_superseded, old_target, new_target}` message and can redirect to the new URL. Viewers that don't handle this message recover via the `:DOWN` monitor.
    4. The new PaneStream retries its `{:pane_id, pane_id}` registration, succeeds, and proceeds with normal startup.
  This ensures at most one PaneStream per underlying tmux pane, with no duplicate `pipe-pane`/FIFO pipelines.

### FIFO Errors
- FIFO directory doesn't exist → create it in PaneStream init
- FIFO already exists (stale from crash) → remove and recreate
- Permission denied → log error, return `{:error, :fifo_permission_denied}`

## Resolved Design Decisions

1. **Capture strategy → pipe-pane**: True streaming via `tmux pipe-pane` to a FIFO, read by a `cat` Port. Initial scrollback captured via `capture-pane -e` (with ANSI escape sequences preserved) and written into the ring buffer. The startup sequence (Port first, then pipe-pane, then capture-pane, then seed buffer) avoids both FIFO deadlock and missed output. Brief overlap between scrollback capture and pipe stream is accepted (not deduplicated) — the format mismatch between capture-pane and raw pipe-pane output makes byte-level deduplication infeasible without server-side terminal emulation.

2. **History → unified ring buffer**: Initial scrollback is written into the ring buffer at startup. All viewers — first or late — receive history from this single buffer. Buffer size is computed dynamically from the pane's tmux `history-limit` × width, clamped between 512KB and 8MB (default 2MB fallback). Under memory pressure (BEAM memory exceeds `memory_high_watermark`), new panes use the minimum buffer size. Old content rolls off naturally as new output streams in.

3. **Multiple viewers → Shared PaneStream**: One PaneStream per pane, shared across all viewers via PubSub. Reference-counted via monitored PIDs with a grace period on last-viewer-disconnect.

4. **Session creation → Yes**: The session list page always shows a "New Session" option alongside existing sessions. User provides a session name (validated: alphanumeric/hyphens/underscores only); optionally a starting command.

5. **Clipboard → Yes**: Copy via xterm.js selection + Clipboard API. Paste via toolbar button (mobile) or Ctrl+Shift+V (desktop). Requires secure context (localhost or HTTPS). Fallback to execCommand for older browsers.

6. **Web transport → LiveView push_event**: Terminal I/O on web flows through the existing LiveView WebSocket. No second WebSocket connection. Phoenix Channel is future, only for native Android client.

7. **Input encoding → send-keys -H (hex)**: All input bytes converted to hex and sent via `tmux send-keys -H`. Handles printable text, control characters, and escape sequences uniformly. No branching between literal and raw modes.

8. **FIFO blocking → cat Port**: The `cat` command runs as a Port (separate OS process), blocking on FIFO open without blocking the GenServer. `pipe-pane` opens the write end, unblocking `cat`. Simple and reliable.

9. **Process lookup → Elixir Registry**: PaneStreams registered in `RemoteCodeAgents.PaneRegistry` with key `{:pane, target}`. `subscribe/1` is a module function (not a GenServer call) that checks Registry for an existing PaneStream; if not found, starts one under DynamicSupervisor via `start_link/1`. It then makes a `GenServer.call` to register the viewer. This "get or start" logic lives inside `subscribe/1` — there is no separate public `get_or_start` function.

10. **Resize conflicts → disabled**: Panes keep their existing dimensions and viewers adapt. Future: last-writer-wins with dimension broadcast to all viewers; mobile viewers are passive (read-only resize).

11. **Session name validation → strict**: Only `^[a-zA-Z0-9_-]+$` allowed. Prevents tmux target format breakage from colons/periods in names.

12. **Pane targeting → stable pane_id with dual registration**: PaneStream resolves tmux's stable `pane_id` (e.g., `%0`) during startup and uses it for all tmux commands (`send-keys`, `pipe-pane`, `capture-pane`, existence checks). The human-readable `target` (`session:window.pane`) is used only for the primary Registry key, PubSub topics, display, and URL routing. A secondary Registry key `{:pane_id, pane_id}` detects stale PaneStreams after session/window renames — the new PaneStream supersedes the old one, ensuring at most one PaneStream per underlying tmux pane.

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
13. Health check endpoint (`GET /healthz`)

## Storage Decision: No Database

This application is **fully stateless from a storage perspective**. No database is needed.

| Concern                | Where state lives                                      |
|------------------------|--------------------------------------------------------|
| Session/pane state     | tmux itself (source of truth)                          |
| Streaming state        | PaneStream GenServer memory (ephemeral)                |
| Viewer tracking        | PaneStream GenServer memory (ephemeral)                |
| Auth tokens            | Config file / environment variable (static)            |
| Quick actions          | YAML config file, cached in `Config` GenServer memory      |
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

**Connection**: Client connects to `wss://host:port/socket/websocket` with `%{"token" => "..."}` param. `UserSocket.connect/3` verifies the token. Rejected connections receive a socket error — the client should prompt for a new token.

**Join**: `"terminal:{session}:{window}:{pane}"` — server converts to target format, calls `PaneStream.subscribe/1`.
- **Success reply**: `{:ok, %{"history" => base64_binary, "cols" => int, "rows" => int}}` — ring buffer contents and current pane dimensions.
- **Error reply**: `{:error, %{"reason" => "pane_not_found" | "max_pane_streams"}}`.

**Events**:

| Direction | Event | Payload | Notes |
|-----------|-------|---------|-------|
| C→S | `input` | `%{"data" => base64_binary}` | Keyboard/touch input. Max 128KB decoded. |
| C→S | `resize` | `%{"cols" => int, "rows" => int}` | Client requests pane resize. Validated: cols 1–500, rows 1–200. Calls `tmux resize-pane` (unlike Phase 1 LiveView, which stores only). |
| S→C | `output` | `%{"data" => base64_binary}` | Streaming terminal output |
| S→C | `reconnected` | `%{"data" => base64_binary}` | Full buffer after PaneStream crash recovery. Client should clear and re-render. |
| S→C | `pane_dead` | `%{}` | Pane/session ended |
| S→C | `pane_superseded` | `%{"new_target" => string}` | Session/window renamed. Client can rejoin under new topic. |
| S→C | `resized` | `%{"cols" => int, "rows" => int}` | Pane was resized by another viewer |

**Leave/disconnect**: On network drop, Phoenix Channel auto-reconnects. Client re-joins the topic and receives fresh history in the join reply. No special reconnect event needed — the join flow handles it.

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
| Create session | Form with name + optional command | `tmux new-session -d -s {name} [-x cols -y rows] [command]` — command is passed as a single argument to `System.cmd` (list form, no shell interpolation), so no escaping is needed. tmux passes it to the shell via `exec`. |
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

#### New Module

This feature introduces `RemoteCodeAgents.Config` (`lib/remote_code_agents/config.ex`) — a GenServer that holds parsed config in memory, serializes all reads and writes to `~/.config/remote_code_agents/config.yaml`, detects external file changes via mtime polling, and broadcasts updates via PubSub so LiveViews stay in sync. Not part of the base scope.

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
| `id` | string | auto | — | Stable identifier (UUID v4). Auto-generated when omitted (e.g., hand-edited YAML). Used by the API for update/delete. |
| `label` | string | yes | — | Button text (keep short — 1-2 words) |
| `command` | string | yes | — | Full command string sent to the terminal |
| `confirm` | boolean | no | `false` | Show confirmation dialog before executing. Renders as a LiveView modal (not `window.confirm()`) with the command text, "Execute" and "Cancel" buttons. On mobile, the modal uses full-width buttons for easy tap targets. The `"confirm_action"` / `"cancel_action"` LiveView events handle the response. |
| `color` | string | no | `"default"` | Button color hint: `"default"`, `"green"`, `"red"`, `"yellow"`, `"blue"` |
| `icon` | string | no | `null` | Optional icon name (Heroicons subset: `"rocket"`, `"play"`, `"stop"`, `"trash"`, `"arrow-up"`, `"terminal"`). Unrecognized icon names are ignored (no icon rendered). |

#### Config Loading & Persistence

`RemoteCodeAgents.Config` is a **GenServer** that owns all access to the config file. This serializes concurrent writes (multiple browser tabs), enables PubSub-driven LiveView updates, and detects external file edits.

- **Location resolution**: Check `$RCA_CONFIG_PATH` env var first, then `~/.config/remote_code_agents/config.yaml`, then fall back to defaults (no quick actions).
- **Parsing**: Use `yaml_elixir` hex package to parse YAML.
- **Startup**: Reads and validates the config file in `init/1`. Stores the parsed config and the file's mtime in GenServer state. Starts a periodic mtime check via `Process.send_after/3`.
- **File change detection**: Every 2 seconds (`config_poll_interval`, configurable), the GenServer checks the config file's mtime via `File.stat/1`. If the mtime has changed, it re-reads and re-parses the file, updates state, and broadcasts `{:config_changed, config}` on PubSub topic `"config"`. This catches manual YAML edits without needing a filesystem watcher dependency.
- **Reads**: `Config.get/0` makes a `GenServer.call` returning the in-memory config. Fast — no file I/O.
- **Writes**: `Config.update/1` takes a function `(config -> config)`, applies it to the current state, writes to disk atomically (tmp + rename), updates mtime in state, and broadcasts `{:config_changed, config}` via PubSub. The mtime is updated from the freshly-written file's stat, so the next poll cycle won't trigger a redundant reload.
- **Validation**: On load, validate each quick action entry. Log warnings for invalid entries (missing `label`/`command`, unknown `color`) and skip them rather than crashing.
- **Missing file**: If no config file exists, the GenServer runs with defaults — no quick actions shown, no error. The mtime is stored as `nil`; any future file creation is detected by the poll.
- **Malformed file**: If the YAML is malformed on reload, `get/0` returns the last good config (still in GenServer state) and logs a warning. This is safer than the "fall back to defaults" approach — the user doesn't lose their action bar while fixing a typo.
- **Auto-creation on save**: `update/1` calls `File.mkdir_p!/1` on the parent directory before writing. If a user creates their first quick action via the Settings UI and no config file exists yet, it will be created automatically.
- **PubSub topic**: `"config"` — LiveViews subscribe on mount and update assigns on `{:config_changed, config}`.

```elixir
defmodule RemoteCodeAgents.Config do
  use GenServer

  @default_path "~/.config/remote_code_agents/config.yaml"
  @poll_interval Application.compile_env(:remote_code_agents, :config_poll_interval, 2_000)

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current in-memory config."
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc """
  Atomically update config. Takes a function (config -> config).
  Writes to disk, updates state, broadcasts change.
  """
  def update(fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, fun})
  end

  # Convenience wrappers for quick action CRUD
  def upsert_action(params), do: update(&do_upsert_action(&1, params))
  def delete_action(id), do: update(&do_delete_action(&1, id))
  def reorder_actions(ids), do: update(&do_reorder_actions(&1, ids))

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    path = config_path() |> Path.expand()
    {config, mtime} = load_from_disk(path)
    schedule_poll()
    {:ok, %{config: config, mtime: mtime, path: path}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:update, fun}, _from, state) do
    updated = fun.(state.config)
    write_to_disk!(state.path, updated)
    mtime = file_mtime(state.path)
    broadcast_change(updated)
    {:reply, {:ok, updated}, %{state | config: updated, mtime: mtime}}
  end

  @impl true
  def handle_info(:poll_config, state) do
    new_mtime = file_mtime(state.path)
    state =
      if new_mtime != state.mtime and new_mtime != nil do
        case load_from_disk(state.path) do
          {config, mtime} ->
            broadcast_change(config)
            %{state | config: config, mtime: mtime}
        end
      else
        state
      end
    schedule_poll()
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_poll, do: Process.send_after(self(), :poll_config, @poll_interval)

  defp config_path, do: System.get_env("RCA_CONFIG_PATH") || @default_path

  defp load_from_disk(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> {parse(yaml), file_mtime(path)}
      {:error, _} -> {defaults(), file_mtime(path)}
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  defp write_to_disk!(path, config) do
    yaml = to_yaml(config)
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, yaml)
    File.rename!(tmp, path)
  end

  defp broadcast_change(config) do
    Phoenix.PubSub.broadcast(RemoteCodeAgents.PubSub, "config", {:config_changed, config})
  end

  defp defaults, do: %{quick_actions: []}

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
      id: entry["id"] || generate_id(),
      label: entry["label"],
      command: entry["command"],
      confirm: entry["confirm"] == true,
      color: validate_color(entry["color"]),
      icon: entry["icon"]
    }
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @valid_colors ~w(default green red yellow blue)
  defp validate_color(c) when c in @valid_colors, do: c
  defp validate_color(_), do: "default"

  # CRUD helpers (pure functions on config map)
  defp do_upsert_action(config, params), do: # ... validate and insert/update
  defp do_delete_action(config, id) do
    %{config | quick_actions: Enum.reject(config.quick_actions, &(&1.id == id))}
  end
  defp do_reorder_actions(config, ids) do
    by_id = Map.new(config.quick_actions, &{&1.id, &1})
    %{config | quick_actions: Enum.map(ids, &Map.fetch!(by_id, &1))}
  end
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

`TerminalLive` reads config from the GenServer on mount and subscribes to changes:

```elixir
# terminal_live.ex
def mount(params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(RemoteCodeAgents.PubSub, "config")
  end

  config = RemoteCodeAgents.Config.get()

  socket =
    socket
    |> assign(:quick_actions, config.quick_actions)
    # ... existing assigns ...

  {:ok, socket}
end

# Config changed (file edited externally or via Settings UI / API)
def handle_info({:config_changed, config}, socket) do
  {:noreply, assign(socket, :quick_actions, config.quick_actions)}
end
```

The template renders the action bar:

```heex
<%!-- terminal_live.html.heex --%>
<div :if={@quick_actions != []} class="quick-action-bar flex gap-2 overflow-x-auto px-2 py-1 bg-gray-900 border-b border-gray-700">
  <button
    :for={action <- @quick_actions}
    phx-click="quick_action"
    phx-value-id={action.id}
    class={["quick-action-btn px-3 py-1 rounded-full text-sm whitespace-nowrap",
            action_color_class(action.color)]}
  >
    <%= action.label %><%= if action.confirm, do: " ⚠" %>
  </button>
</div>
```

The `action_color_class/1` helper maps color names to Tailwind classes:

```elixir
defp action_color_class("green"), do: "bg-green-700 text-green-100 border border-green-600"
defp action_color_class("red"), do: "bg-red-700 text-red-100 border border-red-600"
defp action_color_class("yellow"), do: "bg-yellow-700 text-yellow-100 border border-yellow-600"
defp action_color_class("blue"), do: "bg-blue-700 text-blue-100 border border-blue-600"
defp action_color_class(_), do: "bg-gray-700 text-gray-100 border border-gray-600"
```

The event handler sends the command as keystrokes:

```elixir
def handle_event("quick_action", %{"id" => id}, socket) do
  action = Enum.find(socket.assigns.quick_actions, &(&1.id == id))

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
  # Send the command text followed by Enter (newline) as a binary.
  # Return value intentionally ignored: if the pane is dead, the :pane_dead
  # PubSub broadcast triggers the "Session ended" overlay within milliseconds,
  # making a separate error flash redundant.
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
    if connected?(socket) do
      Phoenix.PubSub.subscribe(RemoteCodeAgents.PubSub, "config")
    end

    config = RemoteCodeAgents.Config.get()
    {:ok, assign(socket, :config, config)}
  end

  def handle_event("save_action", %{"action" => action_params}, socket) do
    {:ok, updated} = RemoteCodeAgents.Config.upsert_action(action_params)
    {:noreply, assign(socket, :config, updated)}
  end

  def handle_event("delete_action", %{"id" => id}, socket) do
    {:ok, updated} = RemoteCodeAgents.Config.delete_action(id)
    {:noreply, assign(socket, :config, updated)}
  end

  def handle_event("reorder_actions", %{"ids" => ids}, socket) do
    {:ok, updated} = RemoteCodeAgents.Config.reorder_actions(ids)
    {:noreply, assign(socket, :config, updated)}
  end

  # Also receives PubSub broadcasts if config changes externally
  def handle_info({:config_changed, config}, socket) do
    {:noreply, assign(socket, :config, config)}
  end
end
```

#### Config Module Extensions

Write capabilities (`update/1`, `upsert_action/1`, `delete_action/1`, `reorder_actions/1`) and the `to_yaml/1` serializer are included in the GenServer definition above. The `to_yaml/1` function produces:

```yaml
# Remote Code Agents configuration
# Edit this file directly or use the web UI at /settings
#
# Quick actions appear as buttons above the terminal.
# Fields: label (required), command (required), confirm, color, icon

quick_actions:
  - id: "abc123"
    label: "Status"
    command: "git status"
    ...
```

#### REST API (for Android App)

Extends the future REST API (described in Future 2) with config endpoints:

```
GET    /api/config              — returns full config as JSON
GET    /api/quick-actions       — returns quick actions list
POST   /api/quick-actions       — add a new quick action (returns the created action with its generated id)
PUT    /api/quick-actions/:id   — update a quick action by stable id
DELETE /api/quick-actions/:id   — delete a quick action by stable id
PUT    /api/quick-actions/order — reorder quick actions (body: {"ids": ["id1","id2","id3"]})
```

**Why IDs, not list indices**: Index-based addressing is fragile — if two clients read the list and one deletes an item, the other client's indices become stale and would target the wrong action. Stable IDs (auto-generated UUIDs) prevent this.

All endpoints require the same bearer token auth as other API routes.

**Response format**:
```json
{
  "quick_actions": [
    {"id": "abc123", "label": "Status", "command": "git status", "confirm": false, "color": "default", "icon": null},
    {"id": "def456", "label": "Push", "command": "git add . && git commit -m . && git push", "confirm": true, "color": "default", "icon": null}
  ]
}
```

#### Controller

```elixir
defmodule RemoteCodeAgentsWeb.QuickActionController do
  use RemoteCodeAgentsWeb, :controller

  def index(conn, _params) do
    config = RemoteCodeAgents.Config.get()
    json(conn, %{quick_actions: config.quick_actions})
  end

  def create(conn, %{"action" => action_params}) do
    {:ok, updated} = RemoteCodeAgents.Config.upsert_action(action_params)
    json(conn, %{quick_actions: updated.quick_actions})
  end

  def update(conn, %{"id" => _id, "action" => action_params}) do
    {:ok, updated} = RemoteCodeAgents.Config.upsert_action(action_params)
    json(conn, %{quick_actions: updated.quick_actions})
  end

  def delete(conn, %{"id" => id}) do
    {:ok, updated} = RemoteCodeAgents.Config.delete_action(id)
    json(conn, %{quick_actions: updated.quick_actions})
  end

  def reorder(conn, %{"ids" => ids}) do
    {:ok, updated} = RemoteCodeAgents.Config.reorder_actions(ids)
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

scope "/", RemoteCodeAgentsWeb do
  pipe_through [:browser, :require_auth]

  live "/settings", SettingsLive
end
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
FROM elixir:1.17-slim AS build
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

The Scope section above defines the Phase 1 (initial) deliverables. The table below prioritizes features beyond Phase 1:

| Priority | Feature | Effort | Rationale |
|----------|---------|--------|-----------|
| P1 | Auth + remote access | Medium | Required to use from mobile — the primary motivation |
| P2 | Pane resize sync | Small | Quality-of-life, simple to implement |
| P3 | Session management (kill, rename) | Small | Basic lifecycle control |
| P4 | Quick actions (command buttons) | Small | High-value for mobile; simple config + UI |
| P5 | User preferences (font, theme) | Small | Client-side only, no server changes |
| P6 | Phoenix Channel + Android client | Large | New client platform, significant effort |
| P7 | Multi-pane split view | Medium | Nice-to-have, complex layout logic |

