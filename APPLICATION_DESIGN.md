# termigate — Application Design

## Overview

A web application built with Elixir, Phoenix, and LiveView that runs on a host computer and provides a browser-based interface to interact with tmux sessions. This enables remote access to terminal sessions — particularly useful for monitoring and interacting with long-running processes, code agents, or development environments.

The application must work well over high-latency and low-bandwidth connections, and be fully usable on mobile browsers. A native Android app is also a target, so the architecture cleanly separates the transport/API layer from the web UI.

**Naming**: The product is called **termigate**. The Elixir project uses `termigate` / `Termigate` as its module namespace and Mix project name (a legacy of the original project scope). The Android app uses package ID `org.tamx.tmuxrm`. All user-facing references (UI, systemd unit, config file headers) use "termigate".

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
    |-- Registry (Termigate.PaneRegistry)
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

2. **Native Android (Phoenix Channel)**: Connects directly to a `TerminalChannel` via a dedicated WebSocket. Speaks a simple binary/JSON protocol. Not used by the web client.

3. **Shared backend**: Both LiveView processes and Channel processes subscribe to the same PubSub topics and call the same PaneStream API. No terminal logic is duplicated.

```
Web browser:
  xterm.js ↔ TerminalHook ↔ LiveView push_event/handle_event ↔ PaneStream

Android app:
  TerminalView ↔ TerminalChannel ↔ PaneStream
```

### Key Modules

#### `Termigate.TmuxManager`
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

#### `Termigate.PaneStream`
- **Responsibility**: Bidirectional bridge between a tmux pane and one or more viewers
- **Registration**: Dual-key via `Registry`:
    1. `{:pane, target}` — primary key, set via GenServer `name:` option at `start_link`. Used by `subscribe/1` to find an existing PaneStream for a given target. Lookup: `Registry.lookup(Termigate.PaneRegistry, {:pane, target})`.
    2. `{:pane_id, pane_id}` — secondary key, registered manually via `Registry.register/3` during init after resolving the stable `pane_id`. Used to detect stale PaneStreams after a session/window rename (see "Stale PaneStream detection" in Lifecycle below).
- **State**:
  - `target` — the `session:window.pane` identifier (human-readable, used for Registry key, PubSub topic, display, and URL routing)
  - `pane_id` — tmux's stable pane identifier (e.g., `%0`), resolved during startup via `tmux display-message -p -t {target} '#{pane_id}'`. Used for `send-keys` and pane existence checks. Stable across session/window renames.
  - `pipe_port` — Elixir Port running `cat` on the FIFO
  - `viewers` — `MapSet` of subscriber PIDs (monitored)
  - `buffer` — ring buffer (`Termigate.RingBuffer`, a fixed-capacity circular binary buffer; API: `new(capacity)`, `append(buffer, binary)` — overwrites oldest data when full, `read(buffer)` — returns a single contiguous binary by concatenating the two halves, `size(buffer)` — current byte count) of all output (scrollback + streaming). Sized dynamically based on the pane's tmux `history-limit` and width (see Buffer Sizing below). All viewers — first or late — receive the same history from this buffer. `RingBuffer.read/1` returns a single contiguous binary by concatenating the two halves of the circular buffer internally. Note: this allocates a copy up to `ring_buffer_max_size` (default 8MB) per call. This is acceptable for the expected viewer count (single-user tool with a handful of concurrent tabs); if many viewers connect simultaneously to a large-buffer pane, the transient memory spike from concurrent `read/1` copies is bounded by `concurrent_viewers × ring_buffer_max_size` (since subscribes serialize through the GenServer, in practice only one copy exists at a time — the bound applies to the aggregate of copies held by viewers that haven't yet consumed them). Because `subscribe/1` makes a `GenServer.call` that triggers `RingBuffer.read/1`, concurrent subscribes to the same pane serialize through the GenServer — during high-throughput output, each subscribe briefly blocks output processing. This is acceptable for the expected concurrency (a few tabs); the call returns quickly since `read/1` is a memory copy, not I/O.
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
  - `send_keys/2` — **module function** that looks up the PaneStream for `target` via Registry and makes a `GenServer.call` to send input. The GenServer handler sends the binary to the pane via `tmux send-keys -H -t {pane_id}` (using the stored stable `pane_id`, not the human-readable `target`). Each byte of the binary is converted to its two-character hex representation. If status is `:dead` or `:starting`, returns `{:error, :pane_dead}` or `{:error, :not_ready}` respectively. If the `send-keys` command fails (e.g., pane died between checks), logs a warning and returns `:ok` — pane death notification will follow shortly via the Port EOF flow. Returns `{:error, :not_found}` if no PaneStream is registered for the target.
- **Lifecycle**:
  - Monitors all viewer PIDs — auto-unsubscribes on viewer crash/disconnect
  - On last viewer unsubscribe: starts a configurable grace period timer (default 30s) via `Process.send_after(self(), :grace_period_expired, ...)`. If a new viewer subscribes within the grace period, cancel the timer via `Process.cancel_timer/1`. When the `:grace_period_expired` message arrives in `handle_info`, re-check `MapSet.size(viewers) == 0` before proceeding with shutdown — this eliminates the race between a late subscribe and the timer firing. **Why this is safe**: Even if `Process.cancel_timer/1` returns `false` (the `:grace_period_expired` message is already in the mailbox), the GenServer processes messages sequentially. The subscribe call (which adds the viewer to the MapSet) is a `GenServer.call` that will be processed before or after the timer message. If the subscribe is processed first, the viewer is in the MapSet and the re-check prevents shutdown. If the timer fires first, the re-check sees zero viewers and shuts down — but the subscribe call will then start a fresh PaneStream via the get-or-start logic. Note: in this case, the new PaneStream runs the full startup sequence (including scrollback re-capture), which is correct — the ring buffer from the old PaneStream is gone, so fresh history must be loaded. This is a brief reconnect, not data loss. **Supervisor restart note**: If the GenServer crashes and the supervisor restarts it, the old process's mailbox (including any pending `:grace_period_expired` timer) is discarded with the old process. The restarted GenServer has fresh state — no stale timers to worry about.
  - On `{:superseded, new_target}` cast (another PaneStream claimed this `pane_id` under a new target after a rename): detach `pipe-pane`, clean up FIFO, broadcast `{:pane_superseded, target, new_target}` to viewers via PubSub (viewers can use `new_target` to redirect), then terminate normally. Viewers that don't handle `:pane_superseded` will still recover via the `:DOWN` monitor on the PaneStream PID. Log at `info` level: "PaneStream #{target} superseded by #{new_target} (pane #{pane_id} was renamed)".
  - On Port exit with status 0 (normal EOF — pane died, pipe-pane closed the FIFO): cancel any active grace period timer, set status to `:dead`, broadcast `{:pane_dead, target}` to all viewers via PubSub, clean up FIFO, then terminate. Log at `info` level.
  - On Port exit with non-zero status (`cat` crashed — e.g., OOM-killed, signal): the tmux pane may still be alive. The PaneStream attempts pipeline recovery:
      1. Check if the pane still exists: `tmux display-message -p -t {pane_id} '#{pane_id}'` (using the stored stable pane_id).
      2. If the pane is alive, re-run the pipeline setup: remove stale FIFO, create new FIFO, start new `cat` Port, re-attach `pipe-pane` (using `pane_id`). Do NOT re-capture scrollback — the ring buffer already has history and streaming output, and re-capturing would introduce duplication. Set status back to `:streaming`. Log at `warning` level: "Port exited with status {n}, pane still alive — restarting pipeline".
      3. If recovery fails (pane gone, FIFO error, pipe-pane fails), fall through to the normal death path: set status to `:dead`, broadcast `{:pane_dead, target}`, clean up, terminate. Log at `error` level.
      4. Limit recovery attempts to 3 within a 60-second window to prevent infinite restart loops (e.g., if `cat` is repeatedly killed). After exhausting retries, follow the death path. The retry counter resets after 60 seconds of stable streaming.
    This distinction is safe because exit status 0 from `cat` reliably indicates EOF (the write end of the FIFO was closed, meaning pipe-pane detached because the pane died). Non-zero indicates an abnormal `cat` termination unrelated to pane lifecycle.

#### `Termigate.Tmux.CommandRunner`
- **Responsibility**: Execute tmux CLI commands and return parsed output
- **Interface**:
  - `run/1` — takes a list of argument strings (e.g., `["list-sessions", "-F", "#{session_name}"]`), prepends the tmux binary path and any socket args (see below), executes via `System.cmd/3`. Returns `{:ok, output}` or `{:error, reason}`.
  - `run!/1` — same but raises on error.
- **Rationale**: Single point of contact with the tmux CLI. Makes it easy to mock in tests and add logging/rate-limiting later.
- **Implementation**: Uses `System.cmd/3` with stderr capture. Validates that `tmux` is available on startup.
- **Socket path**: If `config :termigate, tmux_socket` is set, `CommandRunner` prepends `-S <path>` (absolute socket path) or `-L <name>` (named socket) to all tmux commands. This supports non-default tmux server sockets (e.g., when tmux is started with `tmux -L mysocket`). Default: `nil` (use tmux's default socket).
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
       the pane does not exist — return {:error, :pane_not_found}.

  0b. Register pane_id and detect stale PaneStreams:
     — Call `Registry.register(PaneRegistry, {:pane_id, pane_id}, nil)`.
     — If it returns `{:ok, _}`, no collision — proceed normally.
     — If it returns `{:error, {:already_registered, old_pid}}`, a stale
       PaneStream exists for this pane under an old target (session/window
       was renamed). Send `GenServer.cast(old_pid, {:superseded, target})`
       to tell it to shut down. Rather than sleeping in `init/1` (which
       blocks the supervisor), return `{:ok, state, {:continue, :retry_pane_id_registration}}`
       and retry the registration in `handle_continue/2`. If the retry
       also fails, log a warning and proceed without the secondary
       registration — the stale one will still eventually clean up via
       grace period.
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
     — `max_lines` is set to the pane's effective `history-limit` (from step 7),
       limiting the capture to what the ring buffer was sized to hold. This avoids
       pulling more history than the buffer can store. (The ring buffer capacity is
       `history_limit × pane_width`, so `capacity / pane_width = history_limit`.)
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

**Startup sequence rationale**: The entire startup sequence (steps 0–9) runs synchronously in `init/1`. This means `start_link/1` (and therefore the first `subscribe/1` call) blocks until all tmux commands complete. This is accepted — tmux commands execute against tmux's in-memory state and complete in <10ms each on localhost. The alternative (`handle_continue`) would require `subscribe/1` to handle a "still starting" state, adding complexity for negligible latency savings. If tmux becomes unresponsive, the GenServer start will time out via the default 5-second `GenServer.call` timeout in `subscribe/1`, surfacing the problem clearly.

The key insight is that `cat` on a FIFO blocks at the OS level until a writer opens the pipe, but since it's a Port (separate OS process), it doesn't block the Elixir GenServer. The GenServer can proceed to call `pipe-pane` which opens the write end, unblocking `cat`. This avoids the FIFO deadlock without needing `O_NONBLOCK` or `O_RDWR` hacks.

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

**Application startup cleanup (defense-in-depth)**: In `Application.start/2`, before the supervision tree starts: clear the FIFO directory (`File.rm_rf(fifo_dir)` then `File.mkdir_p(fifo_dir)`). This removes stale FIFOs left by a hard kill (SIGKILL) of the entire application, where no cleanup callbacks run. Stale pipe-pane attachments are **not** detached globally at startup — doing so would interfere with any pipe-pane the user has attached independently (e.g., for logging). Instead, each PaneStream detaches any existing pipe-pane on its specific pane during its own startup sequence (step 1), scoping cleanup to only panes the application actively manages. The application should behave like a remote `tmux attach` — it should never surprise the host operator by modifying panes it isn't actively streaming.

**FIFO naming and shell safety**: Target strings like `mysession:0.1` are sanitized for filesystem use using percent-encoding: `:` becomes `%3A` and `.` becomes `%2E`, giving FIFO names like `pane-mysession%3A0%2E1.fifo`. This is collision-free because `%` cannot appear in tmux session names (which match `^[a-zA-Z0-9_-]+$`) or in the window/pane numeric indices. **Shell injection safety**: The resulting FIFO paths contain only `[a-zA-Z0-9_%.-/]` characters, making them safe for interpolation into the `open_port({:spawn, "cat {fifo_path}"})` shell string (step 5) and the `pipe-pane` command's single-quoted argument (step 6). This safety is guaranteed by the composition of: (1) session name validation (`^[a-zA-Z0-9_-]+$`), (2) window/pane indices being numeric, and (3) percent-encoding replacing `:` and `.` with `%XX` sequences. No shell metacharacters can appear in the path.

### Buffer Sizing

The ring buffer is the single source of history for all viewers. Its size is computed dynamically per pane at PaneStream startup:

1. Query the pane's effective `history-limit`: `tmux show-option -wv -t {target} history-limit` (falls back to `tmux show-option -gv history-limit` for the global default)
2. Query the pane width: `tmux list-panes -t {target} -F '#{pane_width}'`
3. Compute: `history_limit × pane_width` bytes (one byte per cell is a rough estimate; ANSI escape sequences from `capture-pane -e` and multi-byte UTF-8 characters add overhead that can exceed this, but most lines aren't full-width, so it roughly balances out)
4. Clamp the result between `ring_buffer_min_size` (default 512KB) and `ring_buffer_max_size` (default 8MB)
5. If either tmux query fails, use `ring_buffer_default_size` (default 2MB)
6. **Memory pressure check**: Before allocating, check `:erlang.memory(:total)` against `memory_high_watermark` (default 768MB). If BEAM memory exceeds the watermark, use `ring_buffer_min_size` instead of the computed size and log a warning: "Memory pressure detected ({current_bytes / 1_048_576}MB used, watermark {watermark_bytes / 1_048_576}MB) — using minimum ring buffer size for pane {target}". (Convert bytes to MB for readability in log output.) Existing PaneStreams are not affected — only new ones are constrained. This provides graceful degradation without requiring a central memory coordinator.

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
2. **Server (Elixir)**: `Base.decode64/1` recovers the raw UTF-8 bytes (invalid base64 is logged and ignored — see `handle_event` in TerminalLive). Convert each byte to its two-character hex representation. Pass to `tmux send-keys -H`.

This mirrors the output path (server base64-encodes, client decodes) for symmetry.

```
Example: User types "hi" then Ctrl+C
  xterm.js onData emits: "hi\x03" (JS string)
  TextEncoder produces: <<0x68, 0x69, 0x03>> (UTF-8 bytes)
  Base64 encoded: "aGkD"
  Sent to server as: %{"data" => "aGkD"}
  Server decodes base64: <<0x68, 0x69, 0x03>>
  PaneStream calls: tmux send-keys -H -t {pane_id} 68 69 03
```

**Why base64 for transport**: LiveView events are JSON-serialized. While raw control characters (`\x03`) are valid in JSON strings, base64 is more explicit, avoids edge cases with binary-unsafe intermediaries, and is symmetric with the output path.

**Why hex mode for tmux**: Simpler than branching between `-l` for printable chars and raw mode for control chars. No escaping edge cases. Works uniformly for all input including Unicode (UTF-8 bytes as hex). Multi-byte UTF-8 sequences (e.g., emoji like 😀 = 4 bytes `F0 9F 98 80`) are sent as individual hex bytes and tmux reassembles them correctly. This should have an explicit integration test.

**Performance**: For typical interactive use, `send-keys -H` with a handful of hex bytes per keystroke is negligible overhead. For bulk paste operations, `PaneStream.send_keys/2` chunks the input bytes into groups of up to 65,536 bytes (well under Linux's default `ARG_MAX` of ~2MB, accounting for hex encoding doubling the size and argument overhead) and sends them as sequential `send-keys -H` calls within the GenServer. This briefly blocks output processing during large pastes, which is acceptable for a single-user tool — large pastes are rare, each `System.cmd` call completes in milliseconds, and output resumes immediately after. If needed, chunked sends could be offloaded to a Task without changing the public interface.

**Input size limit**: `TerminalLive.handle_event("key_input", ...)` validates that the decoded payload does not exceed 128KB. Payloads exceeding this limit are logged and dropped. This prevents a buggy or malicious client from sending arbitrarily large input in a single event. A single `handle_event` can deliver up to 128KB decoded, which `PaneStream.send_keys/2` splits into at most two 64KB chunks for the tmux CLI.

**Input rate limiting**: The client-side input batching (every 16ms, described in Bandwidth Optimization) provides natural throttling. On the server side, `PaneStream.send_keys/2` does not rate-limit — each call executes a `tmux send-keys` command immediately. If a misbehaving client floods `send_keys` calls, the tmux process is the bottleneck (each `send-keys` is a short-lived fork). This is acceptable for a single-user tool; if needed, a per-viewer token bucket could be added in `PaneStream`.

### LiveView Pages

#### `TermigateWeb.SessionListLive`
- Route: `/`
- Lists all active tmux sessions with their windows and panes
- "New Session" button/form — creates a new tmux session (name input with validation, optional starting command)
- **Session list updates** use a hybrid approach:
  - **Instant**: Subscribes to PubSub topic `"sessions"` on mount. `TmuxManager.create_session/1` and `kill_session/1` broadcast `{:sessions_changed}` on this topic after mutating state, so the session list updates immediately for app-driven changes.
  - **Polling fallback**: `Process.send_after(self(), :refresh_sessions, interval)` in `handle_info` catches external changes (sessions created/killed from the terminal). Default interval is 3 seconds. This is a lightweight **server-local** call (`tmux list-sessions` reads tmux's in-memory state) — it does not generate network traffic unless the session list actually changed (LiveView only pushes diffs). The interval is configurable via `config :termigate, session_poll_interval: 3_000`.
- Click a pane to navigate to the terminal view via `push_navigate`
- Shows pane dimensions and running command (from `tmux list-panes -F` format)
- Mobile layout: full-width card list, large touch targets
- Empty state: friendly message when no tmux sessions exist, with prominent "Create Session" CTA

#### `TermigateWeb.TerminalLive`
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
  - `handle_info({:pane_superseded, _old_target, new_target})` — session/window was renamed. Calls `PaneStream.unsubscribe(target)`, parses `new_target` by splitting on `:` and `.` (e.g., `"new-name:0.1"` → `session = "new-name"`, `window = "0"`, `pane = "1"`), then redirects to the new URL via `push_navigate(socket, to: ~p"/sessions/#{session}/#{window}/#{pane}")`. The new `TerminalLive` mount re-subscribes under the new target, receiving full history from the (new) PaneStream's ring buffer. The user sees a seamless redirect — the terminal briefly reloads with the correct URL.
  - `handle_info({:DOWN, ref, :process, _pid, _reason})` — PaneStream crashed. The viewer demonitors the old ref, then calls `PaneStream.subscribe(target)` again (which starts or finds the restarted PaneStream). If successful, pushes fresh history to the client (xterm.js `term.reset()` + `term.write(history)` via a `"reconnected"` push event) and monitors the new PID. If the pane no longer exists, transitions to the pane-dead UI. This recovery is transparent to the user — output briefly pauses, then the terminal refreshes with full history.
  - `handle_event("key_input", %{"data" => b64})` → `Base.decode64/1` with error handling (invalid base64 is logged and ignored, not crashed on) → `PaneStream.send_keys(target, bytes)`
  - `handle_event("resize", %{"cols" => c, "rows" => r})` → forwards to `PaneStream` which calls `tmux resize-pane -t {pane_id} -x {cols} -y {rows}` and broadcasts `{:pane_resized, cols, rows}` to all viewers. See Resize Conflict Resolution below.
  - `terminate/2`: calls `PaneStream.unsubscribe(target)`. Note: `terminate/2` is best-effort — it does not run on node crash or hard network timeout. The real safety net is PaneStream's monitor on the viewer PID, which fires a `:DOWN` message and triggers auto-unsubscribe regardless of how the viewer process exits.
  - **LiveView crash recovery**: If the LiveView process itself crashes (or the WebSocket disconnects), Phoenix LiveView automatically reconnects and re-mounts. The `mount/3` callback re-runs the full subscribe flow (subscribe to PubSub, get-or-start PaneStream, receive history), making recovery transparent. The old LiveView PID triggers a `:DOWN` in the PaneStream (auto-unsubscribe); the new LiveView PID subscribes fresh. No special handling is needed beyond the standard mount logic.
- Mobile: on-screen virtual keyboard toolbar (see Mobile UI section)
- Back button / navigation header to return to session list

### Phoenix Channel: `TerminalChannel`

For native Android client only. Not used by the web UI.

- **Topic**: `"terminal:{session}:{window}:{pane}"` — this is the client-facing Channel join topic, not a PubSub topic. The join handler converts it to the internal PaneStream target format (`"terminal:foo:0:1"` → `"foo:0.1"`) and then calls `PaneStream.subscribe/1`, which subscribes to the canonical PubSub topic `"pane:foo:0.1"` — the same topic LiveView uses. The Channel join topic uses colons as delimiters (Phoenix Channel convention), while the internal target uses tmux's native `"session:window.pane"` format.
- **Auth**: Token-based authentication verified in `UserSocket.connect/3` (see Auth Flow — Phoenix Channel below). Channel `join/3` does not re-verify — a valid socket implies a valid user.
- **Join handler**:
  1. Parse topic into target: `"terminal:foo:0:1"` → `"foo:0.1"`.
  2. Call `PaneStream.subscribe/1` — same path as TerminalLive.
  3. Monitor the returned `pane_stream_pid`.
  4. On success, reply `{:ok, %{"history" => base64_string, "cols" => int, "rows" => int}}` — history is the ring buffer contents (base64-encoded, because join replies are JSON text frames), cols/rows are the pane's current dimensions.
  5. On `{:error, :pane_not_found}`, reply `{:error, %{"reason" => "pane_not_found"}}`.
  6. On `{:error, :max_pane_streams}`, reply `{:error, %{"reason" => "max_pane_streams"}}`.
- **Client → Server events**:
  - `"input"` — `%{"data" => raw_binary}` — keyboard input. Raw bytes, validated (max 128KB, same as LiveView), passed to `PaneStream.send_keys/2`.
  - `"resize"` — `%{"cols" => int, "rows" => int}` — client requests pane resize. Forwarded to `tmux resize-pane`. Validated: cols 1–500, rows 1–200.
- **Server → Client events**:
  - `"output"` — `%{"data" => raw_binary}` — streaming terminal output. Raw bytes, no base64.
  - `"reconnected"` — `%{"data" => raw_binary}` — full ring buffer after PaneStream crash recovery. Client should clear its terminal and re-render.
  - `"pane_dead"` — `%{}` — pane/session no longer exists. Client should show a disconnected state.
  - `"pane_superseded"` — `%{"new_target" => "new-name:0.1"}` — PaneStream was replaced due to session/window rename. Client can rejoin under the new topic.
  - `"resized"` — `%{"cols" => int, "rows" => int}` — pane was resized by another viewer. Client should resize its terminal view.
- **Leave/disconnect**: `terminate/2` calls `PaneStream.unsubscribe/1`. Same as LiveView, this is best-effort — the real safety net is PaneStream's monitor on the Channel PID, which triggers auto-unsubscribe on crash or network drop. Phoenix Channels reconnect automatically; on reconnect, the client re-joins the topic and receives fresh history.

### Phoenix Channel: `SessionChannel`

For native Android client only. Provides real-time session list updates, mirroring the polling + PubSub approach used by `SessionListLive` on the web.

- **Topic**: `"sessions"` — this is the client-facing Channel join topic. Not to be confused with the PubSub topic of the same name (the Channel process subscribes to the PubSub topic internally).
- **Auth**: Inherited from `UserSocket.connect/3` — same as `TerminalChannel`. A valid socket implies a valid user.
- **Join handler**:
  1. Subscribe to PubSub topic `"sessions"` — receives `{:sessions_changed}` broadcasts from `TmuxManager.create_session/1` and `kill_session/1`.
  2. Fetch the current session list via `TmuxManager.list_sessions/0` (with panes via `list_panes/1` for each session).
  3. Start a poll timer via `Process.send_after(self(), :poll_sessions, session_poll_interval)` — catches external changes (sessions created/killed from the terminal), same interval as `SessionListLive` (default 3s, configurable via `config :termigate, session_poll_interval`).
  4. Store the last-sent session list in Channel assigns for diffing (only push when the list actually changed).
  5. Reply `{:ok, %{"sessions" => sessions_json}}` — the current session list, so the client has data immediately without a separate REST call.
- **Server → Client events**:
  - `"sessions_updated"` — `%{"sessions" => [%{"name" => string, "windows" => int, "created" => int, "attached" => bool, "panes" => [%{"index" => string, "width" => int, "height" => int, "command" => string}]}]}` — full session list with panes. Pushed whenever the list changes (detected via PubSub broadcast or polling).
- **`handle_info` callbacks**:
  - `{:sessions_changed}` (PubSub) — immediately re-fetch the session list from `TmuxManager`, compare to last-sent list, push `"sessions_updated"` if changed, update assigns.
  - `:poll_sessions` — same as `{:sessions_changed}`: re-fetch, compare, conditionally push. Reschedule the next poll via `Process.send_after/3`. This catches external changes not routed through `TmuxManager` (e.g., `tmux new-session` from the command line).
- **Diffing**: The Channel stores the last-pushed session list (as a serialized term or checksum) in assigns. On each poll or PubSub event, it compares the fresh list to the stored one. If identical, no push is sent — this avoids unnecessary WebSocket traffic. The comparison uses the sorted session data (name, window count, pane list) rather than structural equality, since `TmuxManager` may return lists in different orders.
- **No client → server events**: Session mutations (create, delete) go through the REST API (`/api/sessions`), which calls `TmuxManager` and triggers PubSub broadcasts. The Channel is read-only — it only pushes updates.
- **Leave/disconnect**: `terminate/2` is a no-op — PubSub auto-unsubscribes when the process dies, and the poll timer is discarded with the process mailbox. On reconnect, the client re-joins and receives the current session list in the join reply.

## Data Flow

### Event Reference

#### LiveView Events (TerminalLive ↔ TerminalHook)

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Client → Server | `"key_input"` | `%{"data" => base64_string}` | Keyboard/paste input. Decoded to UTF-8 bytes, sent via `send-keys -H`. Max 128KB decoded. |
| Client → Server | `"resize"` | `%{"cols" => int, "rows" => int}` | Terminal dimensions after browser resize. Debounced 300ms client-side. Calls `tmux resize-pane` and broadcasts to other viewers. |
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
| `{:pane_resized, cols, rows}` | integers | Pane dimensions changed. |

#### PubSub Messages (other topics)

| Topic | Message | Description |
|-------|---------|-------------|
| `"sessions"` | `{:sessions_changed}` | Session created or killed via `TmuxManager`. |
| `"config"` | `{:config_changed, config}` | Config file changed (manual edit or UI save). |

#### Phoenix Channel Events (TerminalChannel)

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Client → Server | `"input"` | `%{"data" => raw_binary}` | Keyboard/touch input. Raw bytes, no base64. Max 128KB. |
| Client → Server | `"resize"` | `%{"cols" => int, "rows" => int}` | Client requests pane resize. Validated: cols 1–500, rows 1–200. Calls `tmux resize-pane`. |
| Server → Client | `"output"` | `%{"data" => raw_binary}` | Streaming terminal output. Raw bytes, no base64. |
| Server → Client | `"reconnected"` | `%{"data" => raw_binary}` | Full buffer after PaneStream crash recovery. Client clears and re-renders. |
| Server → Client | `"pane_dead"` | `%{}` | Pane/session ended. |
| Server → Client | `"pane_superseded"` | `%{"new_target" => string}` | Session/window renamed. Client can rejoin under new topic. |
| Server → Client | `"resized"` | `%{"cols" => int, "rows" => int}` | Pane resized by another viewer. |

**Join reply**: `{:ok, %{"history" => base64_string, "cols" => int, "rows" => int}}` or `{:error, %{"reason" => string}}`. Join replies are JSON text frames, so history is base64-encoded here — the only exception to the raw binary convention. All subsequent data events (`output`, `reconnected`, `input`) use raw binary frames — see "Binary Frames on Phoenix Channel" in Bandwidth Optimization.

#### Phoenix Channel Events (SessionChannel)

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Server → Client | `"sessions_updated"` | `%{"sessions" => [...]}` | Full session list with panes. Pushed on change detection (PubSub or poll). |

**Join reply**: `{:ok, %{"sessions" => [...]}}` — current session list, same format as `"sessions_updated"` payload. No client → server events — mutations use the REST API.

### Terminal Output (tmux → browser)

1. tmux writes output → `pipe-pane` writes to FIFO
2. `cat` Port reads from FIFO → Elixir receives `{port, {:data, bytes}}`
3. PaneStream appends to ring buffer, broadcasts `{:pane_output, bytes}` via PubSub topic `"pane:#{target}"`. Rapid Port messages are coalesced via a short timer (default 3ms) before broadcasting — see Server-Side Output Coalescing in Bandwidth Optimization. All messages on this topic are tagged tuples — subscribers must pattern-match on the first element: `:pane_output` for streaming data, `:pane_dead` for pane death, `:pane_resized` for dimension changes
4. `TerminalLive` receives via `handle_info`, calls `push_event(socket, "output", %{data: Base.encode64(bytes)})`
5. `TerminalHook` decodes base64, calls `term.write(bytes)` on xterm.js instance

Note: Both input and output are base64-encoded for LiveView transport since LiveView events are JSON-serialized. Output: server encodes, client decodes. Input: client encodes (via `TextEncoder` + base64), server decodes. The Channel implementation uses raw binary frames instead (see Binary Frames on Phoenix Channel).

### Initial Attach (history)

1. Viewer calls `PaneStream.subscribe(target)`
2. If PaneStream not running, starts it under DynamicSupervisor:
   a. Port starts `cat` on FIFO (blocks at OS level, not in GenServer)
   b. `pipe-pane` attached (unblocks `cat`)
   c. `capture-pane` captures scrollback, writes into ring buffer (brief overlap with pipe stream is accepted — see Scrollback Overlap)
3. PaneStream returns `{:ok, history, pane_stream_pid}` — ring buffer contents + PID for monitoring
4. TerminalLive monitors `pane_stream_pid` and pushes history to client as `"history"` event
5. Client writes history to xterm.js, then streaming output follows

All viewers — first or late — follow the same path. The ring buffer always contains contiguous history (initial scrollback plus all subsequent streaming output, with old content rolling off as the buffer fills). No separate scrollback handling is needed.

### Keyboard Input (browser → tmux)

1. xterm.js `onData` callback fires with a JavaScript string
2. Hook encodes to UTF-8 via `TextEncoder`, then base64-encodes the bytes
3. Hook calls `this.pushEvent("key_input", {data: base64String})`
4. `TerminalLive.handle_event("key_input", %{"data" => b64})` decodes base64 via `Base.decode64/1` (invalid base64 is logged and ignored), calls `PaneStream.send_keys(target, bytes)`
5. PaneStream converts bytes to hex, executes `tmux send-keys -H -t {pane_id} {hex_bytes}`

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
4. If alive: restarts the pipeline (new FIFO, new Port, re-attach pipe-pane). Broadcasts `{:pane_reconnected, target, buffer_binary}` via PubSub with the current ring buffer contents. Viewers clear their terminal and re-render from the fresh buffer — this avoids subtle rendering corruption from the interrupted stream. Output briefly pauses during recovery (~10-50ms), then resumes normally.
5. If dead (or recovery fails, or retry limit exceeded): follows the normal pane death path above (pane death steps 5-7 — broadcast `:pane_dead`, grace period, cleanup).

**GenServer crash (PaneStream process itself crashes)**:

If PaneStream exits abnormally (e.g., unhandled exception), the supervisor restarts it (`restart: :transient`). However, viewers hold monitors on the *old* process and receive `:DOWN`. Recovery flow:

1. Old PaneStream crashes — supervisor starts a new PaneStream with the same target.
2. New PaneStream re-establishes pipe-pane pipeline, captures fresh scrollback into ring buffer.
3. Viewers receive `{:DOWN, ref, :process, old_pid, reason}` for the old PaneStream.
4. Viewer `handle_info(:DOWN, ...)` calls `PaneStream.subscribe/1` again, which finds the new PaneStream in the Registry.
5. Viewer receives fresh history from the new PaneStream's ring buffer (via the normal subscribe reply), clears and re-renders.

The `reconnected` Channel/LiveView event is used only for pipeline recovery (step 4 above), not for GenServer crashes. GenServer crashes are handled by the viewer re-subscribing after `:DOWN`.

### Resize Conflict Resolution

Multiple viewers sharing a pane creates a conflict: resizing the tmux pane affects all viewers.

**Strategy: Last-writer-wins with dimension reporting**

- Any viewer can send a resize event
- Server applies `tmux resize-pane` with the requested dimensions
- Server broadcasts the new dimensions to ALL viewers via PubSub: `{:pane_resized, cols, rows}`
- Other viewers' xterm.js instances are resized to match via `FitAddon.fit()` or `term.resize(cols, rows)`
- On mobile, the terminal adapts to whatever size the pane currently is rather than requesting a resize. Mobile viewers are "passive resizers" — they read the current pane dimensions on connect and fit to them.

See Pane Resize Sync below for the full implementation details including mobile behavior and conflict mitigation.

## Bandwidth Optimization

The strategies below are chosen to help on slow/high-latency connections without degrading performance on fast ones. Strategies that would add latency on good connections (aggressive frame-rate throttling, large batch windows, delta/diff encoding on top of the already-incremental pipe-pane stream) are intentionally avoided.

### 1. Streaming, Not Polling

`pipe-pane` delivers only actual output — no wasted bandwidth on unchanged frames. This is the single biggest optimization: zero overhead when the pane is idle, and output arrives as soon as tmux processes it.

### 2. WebSocket `permessage-deflate` Compression

Terminal output (text + ANSI escape codes) compresses very well — typical compression ratios of 3–5× for text-heavy output, 2× for ANSI-colored output.

**Implementation**: Enable on the LiveView socket declaration in the Endpoint module:

```elixir
# server/lib/termigate_web/endpoint.ex
socket "/live", Phoenix.LiveView.Socket,
  websocket: [compress: true]  # enables permessage-deflate

socket "/socket", TermigateWeb.UserSocket,
  websocket: [compress: true, connect_info: [:peer_data, :x_headers]]  # Phoenix Channel socket for native clients
```

This is configured on the socket, not on the HTTP listener — `permessage-deflate` is a WebSocket extension negotiated during the HTTP→WebSocket upgrade handshake.

**Why this is safe on fast connections**: `permessage-deflate` is negotiated per-connection at the WebSocket handshake. The compression library (zlib) adds negligible CPU overhead per message. For very small messages (< ~20 bytes), the compressed output may be larger — cowboy handles this gracefully by sending uncompressed when compression doesn't help. No configuration needed per-connection; the transport handles it.

### 3. Server-Side Output Coalescing

During high-throughput output (e.g., `cat large_file`, build logs), the `cat` Port can fire dozens of `{port, {:data, bytes}}` messages per millisecond. Without coalescing, each triggers a separate PubSub broadcast and WebSocket push, creating overhead in message framing, PubSub dispatch, and WebSocket frames.

**Implementation**: PaneStream uses a short coalescing window in `handle_info`:

1. On first `{port, {:data, bytes}}` when no coalesce timer is active: append bytes to an IO list accumulator, start a timer via `Process.send_after(self(), :flush_output, @coalesce_ms)`.
2. On subsequent Port data while the timer is active: append to the accumulator (IO list cons, no copying).
3. On `:flush_output`: convert the IO list to a binary via `IO.iodata_to_binary/1`, append to ring buffer, broadcast `{:pane_output, coalesced_bytes}` via PubSub, clear the accumulator.
4. If the accumulator exceeds a size threshold (e.g., 32KB) before the timer fires, flush immediately — this prevents unbounded memory growth during extreme throughput.
5. `terminate/2` flushes any pending accumulator to the ring buffer before shutdown, minimizing data loss on graceful termination. On hard crashes (e.g., killed by supervisor), up to one coalesce window (~3ms / ≤32KB) of buffered output may be lost from the ring buffer. This is an accepted trade-off — the data was already broadcast to connected viewers in real-time and only affects the ring buffer history for future subscribers.

**Configuration**:

```elixir
# server/config/config.exs
config :termigate,
  # Coalescing window (ms) for PaneStream output. 0 = disabled (every Port
  # message triggers an immediate broadcast). Low values (2-5ms) help on
  # slow connections without perceptible delay on fast ones.
  output_coalesce_ms: 3,
  # Flush immediately if accumulated output exceeds this size (bytes)
  output_coalesce_max_bytes: 32_768  # 32 KB
```

**Why this is safe on fast connections**: A 3ms window is below human perception (~13ms visual frame at 75Hz). On a LAN, it means at most 3ms additional latency on the first byte of a burst. During interactive typing (single characters), the Port typically fires one message at a time — the timer fires 3ms later with just that one message, so overhead is one timer per keystroke echo. During high-throughput output, the coalescing is purely beneficial: fewer, larger WebSocket frames are more efficient even on fast connections due to reduced framing overhead.

### 4. Binary Frames on Phoenix Channel

LiveView requires JSON-serializable payloads, so terminal data is base64-encoded (~33% overhead). The Phoenix Channel for native Android clients uses binary WebSocket frames instead, eliminating this overhead entirely.

**Implementation**: `UserSocket` is configured with Phoenix's V2 JSON serializer (the default for new Phoenix apps). This serializer handles two frame types on the same WebSocket connection:
- **Text frames** (JSON): used for control messages — join, leave, heartbeat, replies, and events with JSON-only payloads (e.g., `resize`, `pane_dead`).
- **Binary frames**: used for data-heavy events — terminal output, input, and history. The binary frame format is: `<<join_ref_size::8, topic_size::8, event_size::8, join_ref::binary, topic::binary, event::binary, payload::binary>>` — a compact header followed by raw payload bytes.

The Channel `handle_info({:pane_output, bytes})` pushes `{:binary, bytes}` as the payload. The serializer encodes this as a binary WebSocket frame automatically. The Android client receives raw bytes via OkHttp's `onMessage(webSocket, bytes: ByteString)` callback and parses the binary header to extract the event name and payload.

This is a pure win — less CPU (no encode/decode) and 33% less bandwidth compared to base64-over-JSON.

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

History buffer sized dynamically per pane (see Resolved Design Decision #2 — "History → unified ring buffer"), clamped between 512KB and 8MB. Provides full scrollback context without excessive transfer on initial attach. Under memory pressure, new panes use the minimum buffer size.

## Clipboard Integration

- **Copy**: xterm.js selection → `navigator.clipboard.writeText()` via the `onSelectionChange` callback. Automatically copies selected text. On mobile, long-press triggers native text selection which xterm.js supports.
- **Paste (desktop)**: Intercept `Ctrl+Shift+V` in the hook's keydown handler. Call `navigator.clipboard.readText()`, then send content as `"key_input"` event (which flows through `send_keys -H`).
- **Paste (mobile)**: "Paste" button in the virtual key toolbar calls `navigator.clipboard.readText()` → sends as `"key_input"` event.
- **Permission**: Clipboard API requires a secure context (HTTPS or localhost). Localhost satisfies this; remote access requires HTTPS (see Authentication & Remote Access).
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
| Auth               | bcrypt_elixir 3.x   | Password hashing via bcrypt (+ comeonin interface). Standard in Phoenix ecosystem. |
| Terminal backend   | tmux pipe-pane      | True streaming, lower latency than polling              |
| Process registry   | Elixir Registry     | Built-in, lightweight process lookup by key            |
| Process management | DynamicSupervisor   | One child per active pane stream                       |
| Pub/Sub            | Phoenix.PubSub      | Built-in; connects PaneStreams to viewers               |
| User config (read) | yaml_elixir 2.11+   | YAML parser for quick actions and settings                 |
| User config (write)| ymlr 5.0+           | YAML encoder for writing config back to file               |
| Mobile terminal    | xterm.js + toolbar  | Works in mobile browsers; virtual key toolbar for special keys |
| Android            | Phoenix Channel     | Direct WebSocket connection; native terminal renderer   |

**TERM environment variable**: xterm.js supports 256-color output and standard ANSI/xterm escape sequences. Tmux sets `TERM` inside its panes based on its `default-terminal` option, which typically defaults to `tmux-256color` or `screen-256color`. Both are compatible with xterm.js. The application does **not** override `TERM` when creating sessions — this is left to the user's tmux configuration. If users experience rendering issues (e.g., missing colors, broken line drawing), they should ensure their tmux config uses a 256-color terminal type: `set -g default-terminal "tmux-256color"`.

## Project Structure

```
termigate/
  server/
    lib/
      termigate/
        application.ex               # Supervision tree
        tmux/
          command_runner.ex           # Thin wrapper around System.cmd for tmux CLI
          session.ex                  # Session struct
          pane.ex                     # Pane struct
        tmux_manager.ex               # Session/pane discovery + creation (stateless module)
        ring_buffer.ex                # Circular byte buffer with fixed capacity (new/1, append/2, read/1, size/1)
        pane_stream.ex                # Per-pane streaming GenServer (pipe-pane + FIFO)
        pane_stream_supervisor.ex     # DynamicSupervisor for PaneStreams
        session_poller.ex             # GenServer: polls tmux session/pane list, broadcasts changes via PubSub
        config.ex                     # GenServer: YAML config loader/writer with mtime polling + PubSub (used by Quick Actions + Settings)
      termigate_web/
        channels/
          terminal_channel.ex         # Raw terminal I/O channel (for native clients)
          session_channel.ex          # Real-time session list updates (for native clients)
          user_socket.ex              # Socket configuration
        plugs/
          require_auth.ex             # Plug: checks session cookie, redirects to /login
          require_auth_token.ex       # Plug: checks bearer token in Authorization header (REST API)
          rate_limit.ex               # Plug: per-IP rate limiting via ETS (login, websocket, session create)
        rate_limit_store.ex           # GenServer: owns rate limit ETS table, periodic cleanup
        controllers/                  # REST API (for native clients)
          auth_controller.ex          # POST /api/login, DELETE /logout — auth endpoints
          health_controller.ex        # GET /healthz endpoint
          session_controller.ex       # Session CRUD API (list, create, delete, rename, create window)
          pane_controller.ex          # Pane API (split, delete)
          config_controller.ex        # GET /api/config — full config as JSON
          quick_action_controller.ex  # CRUD API for quick actions
        live/
          auth_hook.ex                # on_mount hook for LiveView auth checks
          auth_live.ex                # Login page (username + password form)
          auth_live.html.heex         # Login template
          session_list_live.ex        # Session listing + creation page
          session_list_live.html.heex # Template
          terminal_live.ex            # Terminal view page
          terminal_live.html.heex     # Template
          multi_pane_live.ex          # Multi-pane split view (session view)
          multi_pane_live.html.heex   # Template
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
      termigate/
        tmux_manager_test.exs         # Unit tests with mocked CommandRunner
        pane_stream_test.exs          # Integration tests with real tmux
      termigate_web/
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
  ├── Termigate.PaneRegistry (Registry)
  ├── Termigate.PaneStreamSupervisor (DynamicSupervisor)
  ├── Phoenix.PubSub (Termigate.PubSub)
  ├── Termigate.SessionPoller (GenServer)
  ├── Termigate.Config (GenServer)
  ├── TermigateWeb.RateLimitStore (GenServer — owns ETS table, periodic cleanup)
  └── TermigateWeb.Endpoint
```

- `PaneRegistry` starts first — PaneStreams need it for registration
- `PaneStreamSupervisor` starts next — ready to accept PaneStream children. Configured with `max_children: 100` to bound resource usage (FIFOs, ports, memory). If the limit is hit, `subscribe/1` returns `{:error, :max_pane_streams}`. This is configurable via `config :termigate, max_pane_streams: 100`. PaneStream children use `restart: :transient` — they are restarted on abnormal exits but not on `:normal`, `:shutdown`, or `{:shutdown, reason}` exits. All deliberate PaneStream terminations (grace period expiry, pane death, superseded) use `{:stop, :normal, state}` to avoid triggering a supervisor restart.
- PubSub starts before SessionPoller and Config — both broadcast via PubSub
- `SessionPoller` polls tmux for session/pane lists every `session_poll_interval` (default 3s) via `TmuxManager.list_sessions/0`. Compares the result to the previous snapshot; if changed, broadcasts `{:sessions_updated, sessions}` on PubSub topic `"sessions"`. Exposes `SessionPoller.get/0` (GenServer.call) for synchronous reads (e.g., Channel join replies, REST API). This single process replaces per-viewer polling — `SessionListLive` and `SessionChannel` both subscribe to the `"sessions"` PubSub topic and receive updates without their own timers.
- Config starts before Endpoint — config must be loaded before LiveViews mount
- No TmuxManager in the tree — it's a stateless module, not a process

## Configuration

```elixir
# server/config/config.exs
config :termigate,
  # Polling interval (ms) for SessionPoller to check tmux for session/pane changes
  session_poll_interval: 3_000,
  # Grace period (ms) before shutting down a PaneStream with zero viewers
  pane_stream_grace_period: 30_000,
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
  fifo_dir: "/tmp/termigate",
  # Path to tmux binary (auto-detected if nil)
  tmux_path: nil,
  # tmux socket path (-S) or name (-L). nil = default socket.
  # Use absolute path for -S (e.g., "/tmp/tmux-1000/mysocket")
  # or a plain name for -L (e.g., "mysocket")
  tmux_socket: nil,
  # Output coalescing window (ms). Collects rapid Port messages into a single
  # broadcast. 0 = disabled. Low values (2-5ms) reduce overhead on slow
  # connections without perceptible delay on fast ones.
  output_coalesce_ms: 3,
  # Flush coalesced output immediately if accumulated bytes exceed this threshold
  output_coalesce_max_bytes: 32_768,  # 32 KB
  # Auth session/token TTL (days). nil = never expire (re-auth only on explicit logout).
  auth_session_ttl_days: 30

# server/config/dev.exs
config :termigate, TermigateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 8888]
  # WebSocket compression is configured on the socket declaration in endpoint.ex,
  # not here — see Bandwidth Optimization section.

# server/config/test.exs
config :termigate,
  # Use shorter grace period in tests
  pane_stream_grace_period: 100,
  fifo_dir: "/tmp/termigate-test"
```

## Health Check Endpoint

`GET /healthz` — unauthenticated, returns a JSON response indicating application and tmux status.

- **Implementation**: `TermigateWeb.HealthController` — a plain Phoenix controller (not LiveView).
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
  - Remote mode: Username+password auth required when binding to `0.0.0.0` (see Authentication & Remote Access).
- **Input handling**: All input sent via `send-keys -H` (hex mode) — bytes are passed directly to tmux with no shell interpretation. The user is intentionally sending arbitrary commands to a shell — access control is the real security boundary.
- **Session name validation**: Enforced at `TmuxManager.create_session/1` — only `^[a-zA-Z0-9_-]+$` accepted. Prevents tmux target format injection.
- **HTTPS**: Required if exposed beyond localhost; configure via Phoenix endpoint or reverse proxy. Also required for Clipboard API access.
- **CSRF**: Phoenix's built-in CSRF protection applies to all LiveView forms (login, settings, session creation). REST API routes (`/api/*`) are exempt — they use bearer token auth via `Authorization` header, which is not vulnerable to CSRF (tokens are not auto-attached by the browser like cookies are).
- **CORS**: Not configured. The REST API is consumed by the native Android app (no CORS needed) and the web UI uses LiveView (same-origin). Cross-origin browser access to the API is not a supported use case.
- **Channel auth**: `TerminalChannel` verifies auth token on join to prevent unauthorized WebSocket connections from native apps
- **FIFO permissions**: Created via `mkfifo -m 0600` (owner read/write only, set at creation time) to prevent other users on the host from reading terminal output
- **Rate limiting**: Per-IP rate limits protect against brute-force and abuse on internet-facing deployments. Implemented as a Plug that tracks request counts per IP using `:ets` (no external dependencies). Rate limit state is lost on application restart — acceptable since restart clears the attack window anyway. Only applied when auth is enabled (remote mode); in localhost mode, rate limiting is skipped.

  | Endpoint | Limit | Window | Response on exceed |
  |----------|-------|--------|--------------------|
  | `POST /api/login` | 5 requests | 1 minute | `429 Too Many Requests` with `{"error": "rate_limited", "retry_after": seconds}` and `Retry-After` header |
  | WebSocket upgrade (`/socket/websocket`) | 10 attempts | 1 minute | Connection rejected (`:error` from `UserSocket.connect/3`) |
  | `POST /api/sessions` | 10 requests | 1 minute | `429 Too Many Requests` with same format |

  **Implementation**: `TermigateWeb.Plugs.RateLimit` — a Plug for HTTP endpoints (login, session create). WebSocket rate limiting is handled in `UserSocket.connect/3` instead of a Plug, since WebSocket upgrades bypass the router pipeline — `connect/3` reads the peer IP from `connect_info` and calls `RateLimitStore.check/2` directly. Both paths use the same ETS table (`:set`, `:public`, with `read_concurrency: true`) to track `{ip, endpoint_key, window_start}` → `count`. The window start is truncated to the current minute (`System.system_time(:second) |> div(60)`). Stale entries are cleaned up lazily — on each request, if the window has rolled over, the old entry is replaced. A periodic cleanup (every 5 minutes via a `Process.send_after` loop inside the `RateLimit` module's companion GenServer, started in the supervision tree) sweeps entries older than 2 minutes to prevent unbounded ETS growth from many distinct IPs. The GenServer owns the ETS table; the Plug reads from it directly (`:public` table with `read_concurrency: true`).

  **Configuration**:
  ```elixir
  # server/config/config.exs
  config :termigate,
    rate_limits: %{
      login: {5, 60},           # {max_requests, window_seconds}
      websocket: {10, 60},
      session_create: {10, 60}
    }
  ```

  **Why these limits**: `/api/login` is the most sensitive — 5 per minute allows a few typos but makes brute-force impractical (at 5/min, a 6-character lowercase password would take ~190 years). WebSocket and session creation limits are higher since they require auth (a compromised token) and are less likely attack vectors. All limits are configurable for users who want stricter or more lenient settings.

  **IP extraction**: Uses `conn.remote_ip` which respects `x-forwarded-for` if the endpoint is configured with `Plug.RewriteOn` (needed behind a reverse proxy). Users deploying behind nginx/Caddy should configure `Plug.RewriteOn` in the endpoint to avoid all requests appearing as `127.0.0.1`.

  **Not rate limited** (and why):
  - Authenticated REST reads (`GET /api/sessions`, `GET /api/quick-actions`) — cheap, bounded by data size, require valid token
  - Channel events (`"input"`, `"resize"`) — post-authentication, bounded by tmux throughput
  - LiveView mounts (`/live` WebSocket) — protected by session cookie, Phoenix has built-in connection limits. A single-user tool with cookie auth makes LiveView-level rate limiting unnecessary; the auth check itself is the gate.
  - `GET /healthz` — intentionally open for monitoring; returns static data, negligible cost

- **BEAM distribution**: The Erlang distribution protocol must be disabled in production when the app is exposed beyond localhost. Distribution allows arbitrary code execution by anyone who knows the BEAM cookie. The Mix release should start with `--no-epmd` and the endpoint should not enable distribution (this is the default for `mix release` in production). If remote BEAM debugging is needed, use `--remsh` over SSH rather than exposing distribution on the network.

## Testing Strategy

### Unit Tests
- **TmuxManager**: Mock `CommandRunner` to return canned tmux output. Test parsing of `list-sessions`, `list-panes` format strings. Test session name validation. Test error cases (tmux not running, session doesn't exist).
- **PaneStream**: Test state machine logic (subscribe/unsubscribe/grace period) with mocked tmux commands. Test ring buffer behavior (append, cap, read).

### Integration Tests
- **PaneStream + tmux**: Start a real tmux session in test setup, attach PaneStream, send keys, verify output arrives. Requires tmux installed in CI.
- **LiveView**: Use `Phoenix.LiveViewTest` — mount `TerminalLive`, simulate events, verify `push_event` calls. Mock PaneStream for isolation.
- **SessionListLive**: Mount, verify session listing renders. Test "New Session" form submission.

### Test Helpers (`server/test/support/tmux_helpers.ex`)
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
- **Display impact**: The PaneStream's `target` field and the URL still reflect the old name. The `SessionPoller` broadcast (every 3s) will update `SessionListLive` with the new session name. The user can navigate to the renamed pane via the new URL.
- **Stale URLs**: If a user navigates to the old URL (e.g., a bookmark), `subscribe/1` attempts to start a PaneStream for the old target name, which fails with `{:error, :pane_not_found}` since the session no longer exists under that name. The user sees the pane-not-found error UI and can navigate back to the session list to find the renamed session. No automatic redirect from old-name URLs is attempted — this is a known limitation accepted for simplicity.
- **Stale PaneStream detection and cleanup**: When a viewer navigates to the new name, `subscribe/1` starts a new PaneStream under the new target. During init, the new PaneStream resolves `pane_id` and attempts to register `{:pane_id, pane_id}` in the Registry. This collides with the old PaneStream's registration, triggering the supersede flow:
    1. The new PaneStream sends `{:superseded, new_target}` to the old PaneStream.
    2. The old PaneStream detaches its `pipe-pane`, cleans up its FIFO, broadcasts `{:pane_superseded, old_target, new_target}` to its viewers, and terminates normally.
    3. Viewers of the old PaneStream receive the `{:pane_superseded, old_target, new_target}` message. **Web (LiveView)**: `TerminalLive.handle_info` calls `push_navigate(socket, to: ~p"/terminal/#{new_target}")` to redirect to the new URL. **Channel (Android)**: `TerminalChannel` pushes a `"pane_superseded"` event with the new target; the client leaves the old topic and re-joins under the new one (see Android Terminal Screen lifecycle step 8). Viewers that don't handle this message recover via the `:DOWN` monitor.
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

6. **Web transport → LiveView push_event**: Terminal I/O on web flows through the existing LiveView WebSocket. No second WebSocket connection. Phoenix Channel is used only for the native Android client.

7. **Input encoding → send-keys -H (hex)**: All input bytes converted to hex and sent via `tmux send-keys -H`. Handles printable text, control characters, and escape sequences uniformly. No branching between literal and raw modes.

8. **FIFO blocking → cat Port**: The `cat` command runs as a Port (separate OS process), blocking on FIFO open without blocking the GenServer. `pipe-pane` opens the write end, unblocking `cat`. Simple and reliable.

9. **Process lookup → Elixir Registry**: PaneStreams registered in `Termigate.PaneRegistry` with key `{:pane, target}`. `subscribe/1` is a module function (not a GenServer call) that checks Registry for an existing PaneStream; if not found, starts one under DynamicSupervisor via `start_link/1`. It then makes a `GenServer.call` to register the viewer. Returns `{:ok, history_binary, cols, rows}` on success or `{:error, reason}` (where reason is `:pane_not_found`, `:max_pane_streams`, etc.) on failure. This "get or start" logic lives inside `subscribe/1` — there is no separate public `get_or_start` function.

    **Race condition handling**: If two viewers call `subscribe/1` concurrently for the same target, both may see "not found" in Registry and attempt `DynamicSupervisor.start_child`. PaneStream's `init/1` registers itself in the Registry via `{:via, Registry, {PaneRegistry, {:pane, target}}}` (the `name` option in `start_link`). The second `start_child` receives `{:error, {:already_started, pid}}` because Registry rejects duplicate keys. `subscribe/1` handles this by extracting the existing PID from the error tuple and proceeding with the `GenServer.call` to register the viewer — same as if the process had been found in the initial lookup.

    **`send_keys/2`**: `PaneStream.send_keys(target, bytes)` is a convenience function that looks up the PaneStream in Registry via `{:pane, target}` and makes a `GenServer.call(:send_keys, bytes)`. Returns `:ok` on success or `{:error, :not_found}` if no PaneStream is registered for that target (e.g., pane is dead, no viewer has subscribed). The GenServer handler converts `bytes` to hex and calls `tmux send-keys -H -t {pane_id} {hex_bytes}` via `CommandRunner`.

10. **Resize conflicts → last-writer-wins**: Any viewer can resize the pane; the new dimensions are broadcast to all other viewers. Mobile viewers are passive resizers by default (read-only resize, with optional "Fit to screen" button).

11. **Session name validation → strict**: Only `^[a-zA-Z0-9_-]+$` allowed. Prevents tmux target format breakage from colons/periods in names.

12. **Pane targeting → stable pane_id with dual registration**: PaneStream resolves tmux's stable `pane_id` (e.g., `%0`) during startup and uses it for all tmux commands (`send-keys`, `pipe-pane`, `capture-pane`, existence checks). The human-readable `target` (`session:window.pane`) is used only for the primary Registry key, PubSub topics, display, and URL routing. A secondary Registry key `{:pane_id, pane_id}` detects stale PaneStreams after session/window renames — the new PaneStream supersedes the old one, ensuring at most one PaneStream per underlying tmux pane.

    **PubSub topics** (complete list):
    - `"pane:{target}"` — per-pane events: `{:pane_output, bytes}`, `{:pane_reconnected, target, buffer_binary}`, `{:pane_resized, cols, rows}`, `{:pane_dead, target}`, `{:pane_superseded, old_target, new_target}`. Subscribed by `TerminalLive` and `TerminalChannel`.
    - `"sessions"` — session list changes: `{:sessions_updated, sessions}`. Published by `SessionPoller`, subscribed by `SessionListLive` and `SessionChannel`.
    - `"config"` — config file changes: `{:config_changed, config}`. Published by `Config` GenServer, subscribed by `TerminalLive` and `SettingsLive`.

## Scope

1. List tmux sessions and panes on the index page
2. Create new tmux sessions from the UI (with name validation)
3. Click a pane to open a full-viewport terminal view with xterm.js
4. Stream output from the pane using pipe-pane (with history on attach)
5. Send keyboard input from the browser to the pane (via send-keys -H)
6. Shared PaneStream with viewer ref counting and grace period
7. Clipboard copy/paste
8. Mobile-responsive layout with virtual key toolbar
9. Pane death detection and user notification
10. Error handling (tmux not installed, pane died, FIFO errors)
11. Pane resize sync (last-writer-wins with broadcast)
12. Health check endpoint (`GET /healthz`)
13. Authentication & remote access (username+password, optional static token)
14. Session management (kill, rename, create window, split pane, kill pane)
15. Quick actions (configurable command buttons, YAML config, Settings UI, REST API)
16. User preferences (font, theme, cursor — client-side `localStorage`)
17. REST API for native clients (login, sessions, quick actions)
18. Phoenix Channel + native Android client support
19. Multi-pane split view

## Storage Decision: No Database

This application is **fully stateless from a storage perspective**. No database is needed.

| Concern                | Where state lives                                      |
|------------------------|--------------------------------------------------------|
| Session/pane state     | tmux itself (source of truth)                          |
| Streaming state        | PaneStream GenServer memory (ephemeral)                |
| Viewer tracking        | PaneStream GenServer memory (ephemeral)                |
| Auth credentials       | `~/.config/termigate/credentials` (bcrypt hash) or `TERMIGATE_AUTH_TOKEN` env var |
| Quick actions          | YAML config file, cached in `Config` GenServer memory      |
| User preferences       | Browser `localStorage` (client-side)                   |
| Layout preferences     | Browser `localStorage` (client-side)                   |

**Rationale**: tmux is the source of truth for all terminal state. Runtime coordination lives in GenServer memory and PubSub. Auth is single-user, handled by a bcrypt-hashed credentials file (or optional static token for headless setups). User preferences (font size, theme, layout) are per-device and belong in the browser. There is no data that requires durable server-side storage.

**Implications**:
- No Ecto dependency, no migrations, no database process to manage
- Application restarts are clean — PaneStreams re-attach to existing tmux sessions on demand
- Deployment is a single binary (Mix release) with zero infrastructure dependencies beyond tmux
- If multi-user support is ever needed (unlikely for this tool's use case), a database could be introduced then

---

## Detailed Feature Designs

### Authentication & Remote Access

**Goal**: Access terminal sessions from a phone or remote machine over the internet, securely.

#### Username + Password Authentication

- **Credentials**: Username and bcrypt-hashed password stored in `~/.config/termigate/credentials`. The username defaults to the system user running the application. The user chooses a memorable password — no random tokens to transfer between devices.
- **Setup**: `mix termigate.setup` Mix task (also triggered on first launch if no credentials file exists):
  1. Prompts for username (pre-filled with `whoami` output)
  2. Prompts for password (with confirmation)
  3. Hashes password via `Bcrypt.hash_pwd_salt/1`
  4. Writes `username:hash` to `~/.config/termigate/credentials` (plain text, one line, colon-delimited — human-inspectable and easy to parse via `String.split(line, ":", parts: 2)`)
- **Password change**: `mix termigate.change_password` — prompts for current password (verified against stored hash), then new password with confirmation.
- **Dependencies**: `bcrypt_elixir` (+ `comeonin`) — the standard password hashing library in the Phoenix ecosystem.

#### Fallback: Static Token (for headless/automated setups)

- **`TERMIGATE_AUTH_TOKEN` env var**: If set (via `config :termigate, auth_token:` in `runtime.exs`), the login page accepts this token in the password field (with any username). The `Auth` module reads the token from application config (`Application.get_env(:termigate, :auth_token)`) and verifies via `Plug.Crypto.secure_compare/2` (constant-time comparison). This supports systemd services, CI, and scripted deployments where interactive setup isn't possible.
- **Precedence**: If `auth_token` is configured, both token auth and credentials auth are accepted — whichever matches. If neither credentials file nor token config exists, auth is disabled (localhost-only mode). If the endpoint is bound to `0.0.0.0` and no auth is configured, log a warning on startup.

#### Auth Flow — Web

1. User navigates to the app. If no valid session cookie, redirect to `/login`.
2. `/login` page shows username and password fields.
3. On submit, server checks:
   a. If `TERMIGATE_AUTH_TOKEN` is set and the password matches (constant-time compare), authenticate.
   b. Otherwise, look up the stored username. If the username doesn't match, call `Bcrypt.no_user_verify/0` (performs a dummy hash to prevent timing-based username enumeration) and reject. If the username matches, verify the password via `Bcrypt.verify_pass/2`.
4. On success, set a signed session cookie (`Plug.Session` with `:cookie` store, signed with `secret_key_base`). Store `authenticated_at: System.system_time(:second)` in the session data. Configured via `config :termigate, auth_session_ttl_days: 30` in application config (not `config.yaml` — auth settings use application config, not the YAML config file, to avoid a circular dependency on the Config GenServer during boot).
5. All LiveView mounts check `on_mount` hook (`AuthHook`) for valid session. `AuthHook` reads `authenticated_at` from the session and compares against `auth_session_ttl_days` (default 30 days; `nil` = never expire, re-auth only on explicit logout). If the timestamp is missing or expired, redirect to `/login` with a flash message ("Session expired, please log in again" for expired vs no message for missing). This gives the server authoritative control over session lifetime — config changes take effect immediately for all existing sessions.
6. **Logout**: `DELETE /logout` (handled by `AuthController`) clears the session cookie and redirects to `/login`. A "Logout" link is shown in the settings panel. For the Android app, logout clears the stored token from `EncryptedSharedPreferences` and navigates to the Login Screen — no server call needed since Phoenix.Token is stateless (the server doesn't track issued tokens).

#### Auth Flow — Phoenix Channel (Android)

1. Android app POSTs credentials to `/api/login` — returns a signed bearer token (Phoenix.Token) on success.
2. App stores the token in local preferences.
3. WebSocket connect sends token as a param: `socket("/socket", UserSocket, params: {"token" => "..."})`
4. `UserSocket.connect/3` checks the per-IP WebSocket rate limit via `RateLimitStore.check(:websocket, peer_ip)` (IP extracted from `connect_info: [:peer_data, :x_headers]`), then verifies the token via `Phoenix.Token.verify/4`. Returns `{:ok, socket}` or `:error`.
5. On `:error` (rate limited or invalid token), the client receives a connection rejection and prompts the user to re-authenticate.
6. Token TTL matches the web session TTL (`auth_session_ttl_days` application config).

#### Implementation Modules

- `TermigateWeb.Plugs.RequireAuth` — Plug that checks session cookie exists, redirects to `/login` if missing. Does not check TTL — that's handled by `AuthHook` on LiveView mount (Plugs run on the initial HTTP request; `AuthHook` runs on every LiveView mount including reconnects, so TTL expiry is checked more frequently).
- `TermigateWeb.Plugs.RequireAuthToken` — Plug that reads bearer token from `Authorization` header, verifies via `Phoenix.Token.verify/4`, returns 401 on failure. Used by the `:require_auth_token` pipeline for REST API routes.
- `TermigateWeb.AuthLive` — LiveView for the web login page (username + password form, submits via `handle_event`). The REST API login (`POST /api/login`) is handled by `AuthController` — a separate path for native clients.
- `TermigateWeb.AuthController` — handles `POST /api/login` (returns Phoenix.Token for native clients) and `DELETE /logout` (clears session cookie, redirects to `/login`)
- `TermigateWeb.AuthHook` — `on_mount` hook for LiveView auth checks (used in `live_session` block in router)
- `Termigate.Auth` — module that handles credential verification (bcrypt check, token fallback, credentials file I/O)

#### HTTPS

For remote access, HTTPS is required (both for security and Clipboard API).

**Options** (choose one at deployment time):
1. **Reverse proxy**: nginx/Caddy in front, handles TLS termination. App stays on HTTP internally. Simplest if the host already runs a reverse proxy.
2. **Phoenix direct TLS**: Configure `:https` in endpoint config with cert/key paths. Works with Let's Encrypt certs (certbot) or self-signed certs.
3. **Tailscale/WireGuard**: VPN-based access. No public exposure, no certs needed. App stays HTTP on the Tailscale interface. Easiest for personal use.

**Recommendation for personal use**: Tailscale. Zero configuration TLS (MagicDNS provides HTTPS via `tailscale cert`), no port forwarding, no public exposure. The app binds to the Tailscale interface IP instead of `127.0.0.1`.

```elixir
# server/config/runtime.exs — remote access example
config :termigate,
  auth_token: System.get_env("TERMIGATE_AUTH_TOKEN")  # optional fallback for headless setups

config :termigate, TermigateWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 8888]
```

### Phoenix Channel + Native Android Client

**Goal**: Android app connects directly to the server via WebSocket, renders terminal natively.

#### Channel Protocol

The `TerminalChannel` speaks a simple protocol over the Phoenix Channel WebSocket:

**Connection**: Client connects to `wss://host:port/socket/websocket` with `%{"token" => "..."}` param. `UserSocket.connect/3` checks the per-IP rate limit, then verifies the token. Rejected connections receive a socket error — the client should prompt for a new token.

**Join**: `"terminal:{session}:{window}:{pane}"` — server converts to target format, calls `PaneStream.subscribe/1`.
- **Success reply**: `{:ok, %{"history" => base64_string, "cols" => int, "rows" => int}}` — ring buffer contents and current pane dimensions. The reply is a JSON text frame (Phoenix Channel replies are always JSON), so history is base64-encoded — the only exception to the raw binary convention. All subsequent data events use binary frames.
- **Error reply**: `{:error, %{"reason" => "pane_not_found" | "max_pane_streams"}}`.

**Events**:

Events carrying terminal data (`output`, `reconnected`, `input`) are sent as **binary WebSocket frames** using the V2 binary format (see "Binary Frames on Phoenix Channel" in Bandwidth Optimization). Control events (`resize`, `pane_dead`, `pane_superseded`, `resized`) use **JSON text frames**.

| Direction | Event | Frame type | Payload | Notes |
|-----------|-------|------------|---------|-------|
| C→S | `input` | binary | raw bytes | Keyboard/touch input. Max 128KB. |
| C→S | `resize` | JSON | `%{"cols" => int, "rows" => int}` | Client requests pane resize. Validated: cols 1–500, rows 1–200. Calls `tmux resize-pane`. |
| S→C | `output` | binary | raw bytes | Streaming terminal output. |
| S→C | `reconnected` | binary | raw bytes | Full ring buffer after pipe-pane pipeline recovery (Port crash, not GenServer crash). Client should clear terminal and re-render from this buffer. |
| S→C | `pane_dead` | JSON | `%{}` | Pane/session ended |
| S→C | `pane_superseded` | JSON | `%{"new_target" => string}` | Session/window renamed. Client can rejoin under new topic. |
| S→C | `resized` | JSON | `%{"cols" => int, "rows" => int}` | Pane was resized by another viewer |

**Binary frame dispatch**: Phoenix's V2 serializer deserializes incoming binary frames into `%Phoenix.Socket.Message{}` structs (extracting the event name from the binary header) before dispatching to `handle_in/3`. This means `handle_in("input", payload, socket)` works identically for binary and JSON frames — the Channel code does not need to distinguish frame types. The `payload` for binary frames is the raw bytes (as an Elixir binary), not a JSON-decoded map. The Channel should pattern-match accordingly: `handle_in("input", {:binary, bytes}, socket)` for binary payloads vs `handle_in("resize", %{"cols" => c, "rows" => r}, socket)` for JSON payloads.

**Leave/disconnect**: On network drop, Phoenix Channel auto-reconnects. Client re-joins the topic and receives fresh history in the join reply. No special reconnect event needed — the join flow handles it.

**Session management**: The Android app needs to list/create/delete sessions. Two transports are used:

1. **REST API** (`/api/sessions`): For mutations (create, delete) and initial fetch. Reads from `SessionPoller.get/0` for listings. Simple, stateless, protected by bearer token auth.
2. **`SessionChannel`**: For real-time session list updates. The Android app joins the `"sessions"` topic on connect. The `SessionChannel` subscribes to PubSub topic `"sessions"` and forwards `{:sessions_updated, sessions}` broadcasts from `SessionPoller` as `"sessions_updated"` push events to the client. No per-Channel polling — the shared `SessionPoller` handles all tmux queries.

```
POST   /api/sessions             — create session (body: {"name": "...", "command": "..."})
GET    /api/sessions             — list sessions with panes (initial fetch, pull-to-refresh)
DELETE /api/sessions/:name       — kill session
PUT    /api/sessions/:name       — rename session (body: {"name": "new-name"})
POST   /api/sessions/:name/windows — create window in session
POST   /api/panes/:target/split  — split pane (body: {"direction": "horizontal" | "vertical"})
DELETE /api/panes/:target        — kill pane
```

**SessionChannel events**:

| Direction | Event | Payload | Notes |
|-----------|-------|---------|-------|
| S→C | `sessions_updated` | `%{"sessions" => [...]}` | Full session list with panes. Pushed on change detection. |

The `SessionChannel` join reply includes the current session list, so the client gets data immediately without a separate REST call. REST endpoints remain for mutations and as a fallback (e.g., pull-to-refresh).

#### Android App Architecture (high-level)

- **Terminal rendering**: Use [Termux's terminal-emulator](https://github.com/termux/termux-app/tree/master/terminal-emulator) library or a similar Android terminal widget. Receives raw bytes from the Channel, renders natively.
- **WebSocket client**: Use Phoenix's official JavaScript client via a WebView bridge, or a native Kotlin WebSocket client implementing the Phoenix Channel protocol (libraries exist, e.g., `JavaPhoenixClient`).
- **Input**: Android's native keyboard input → convert to terminal bytes → send via Channel `input` event.
- **Offline/reconnect**: Channel automatically reconnects on network drop. On reconnect, re-join the topic — server sends fresh history from the ring buffer. Native terminal clears and re-renders.

### Pane Resize Sync

**Goal**: Viewers can resize the tmux pane, and all viewers stay in sync.

#### Strategy: Last-Writer-Wins with Broadcast

1. Any viewer sends `"resize"` event with `{cols, rows}`.
2. Server calls `tmux resize-pane -t {pane_id} -x {cols} -y {rows}`.
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
| Create session | Form with name + optional command | `tmux new-session -d -s {name} [-x cols -y rows] [command]` — command is passed as a single argument to `System.cmd` (list form), so the Elixir→tmux boundary has no shell interpolation. Note: tmux itself passes the command to the user's shell via `exec`, so shell features (pipes, `&&`, env vars) work as expected. This is intentional — the user is providing a command they want to run. |
| Kill session | Confirmation dialog per session | `tmux kill-session -t {name}` |
| Rename session | Inline edit on session name | `tmux rename-session -t {old} {new}` (with name validation) |
| Create window | "+" button within a session | `tmux new-window -t {session}` |
| Split pane (horizontal) | "Split │" button on pane action menu | `tmux split-window -h -t {target}` — panes side-by-side, vertical divider |
| Split pane (vertical) | "Split ─" button on pane action menu | `tmux split-window -v -t {target}` — panes stacked, horizontal divider |
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

- **Route**: `/sessions/:session/windows/:window` shows all panes in the specified window, laid out to match tmux's actual pane layout. `/sessions/:session` redirects to the session's active window (via `tmux display-message -p -t {session} '#{window_index}'`).
- **Window tabs**: A tab bar across the top of the multi-pane view, one tab per window in the session. Tabs show the window index and name (if set). Clicking a tab navigates to that window's URL. Tabs update from `SessionPoller` broadcasts — window add/remove/rename is detected automatically.
- **Layout discovery**: `MultiPaneLive` polls `tmux list-panes -t {session}:{window} -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'` every 2-3s to get pane positions and sizes. This is separate from `SessionPoller` — layout coordinates are only needed by this view, so `SessionPoller` stays lean (session names, window counts, pane summaries). `MultiPaneLive` also subscribes to the `"sessions"` PubSub topic to detect window add/remove for tab updates.
- **Rendering**: CSS Grid layout with each pane mapped to a grid area based on its tmux coordinates. Each pane gets its own xterm.js instance and PaneStream subscription.
- **Layout refresh**: The `list-panes` poll (above) detects layout changes from user splits/closes/resizes via tmux commands. On change, the CSS Grid is re-rendered to match the new layout.

#### Resize Behavior

In multi-pane view, all panes are **passive resizers** — they read the current pane dimensions and render at that size. Individual panes do not send resize events when the browser window changes. The tmux layout (split ratios, pane sizes) is controlled by tmux itself, and the web view mirrors it. Users who want to resize panes should use tmux commands (`resize-pane`) or the single-pane full-viewport view.

#### Single-Pane Fallback

- Clicking a specific pane from the session list still opens the full-viewport single-pane view (existing `TerminalLive`)
- The multi-pane view is a new route/LiveView that manages multiple `TerminalHook` instances

#### Mobile Behavior

- Multi-pane view is desktop/tablet only (>640px)
- On mobile, the session view shows window tabs at the top and a list of panes for the selected window — tap a pane to open full-viewport
- Alternatively: horizontal swipe between panes in the same window

### Quick Actions (Command Buttons)

**Goal**: Configurable buttons that send pre-defined commands to the terminal with a single tap — especially valuable on mobile where typing long commands is painful.

#### New Module

This feature introduces `Termigate.Config` (`server/lib/termigate/config.ex`) — a GenServer that holds parsed config in memory, serializes all reads and writes to `~/.config/termigate/config.yaml`, detects external file changes via mtime polling, and broadcasts updates via PubSub so LiveViews stay in sync.

#### Configuration File

Quick actions are defined in a YAML configuration file at `~/.config/termigate/config.yaml`. This file is the central place for quick actions and other non-auth settings. Auth credentials are stored separately (see Authentication & Remote Access).

```yaml
# ~/.config/termigate/config.yaml

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
| `id` | string | no | auto-generated | Stable identifier. Auto-generated (URL-safe random token) when omitted (e.g., hand-edited YAML). If any actions are missing IDs on load, the file is rewritten with generated IDs to ensure stability across reloads and API clients. Used by the API and Android app for update/delete. |
| `label` | string | yes | — | Button text (keep short — 1-2 words) |
| `command` | string | yes | — | Full command string sent to the terminal. Max 4096 bytes — validated on save (UI and API reject longer commands). In practice, commands are a few hundred bytes; the limit prevents accidental megabyte payloads. |
| `confirm` | boolean | no | `false` | Show confirmation dialog before executing. Renders as a LiveView modal (not `window.confirm()`) with the command text, "Execute" and "Cancel" buttons. On mobile, the modal uses full-width buttons for easy tap targets. The `"confirm_action"` / `"cancel_action"` LiveView events handle the response. |
| `color` | string | no | `"default"` | Button color hint: `"default"`, `"green"`, `"red"`, `"yellow"`, `"blue"` |
| `icon` | string | no | `null` | Optional icon name (Heroicons subset: `"rocket"`, `"play"`, `"stop"`, `"trash"`, `"arrow-up"`, `"terminal"`). Unrecognized icon names are ignored (no icon rendered). |

#### Config Loading & Persistence

`Termigate.Config` is a **GenServer** that owns all access to the config file. This serializes concurrent writes (multiple browser tabs), enables PubSub-driven LiveView updates, and detects external file edits.

- **Location resolution**: Check `$TERMIGATE_CONFIG_PATH` env var first, then `~/.config/termigate/config.yaml`, then fall back to defaults (no quick actions).
- **Parsing**: Use `yaml_elixir` hex package to parse YAML.
- **Startup**: Reads and validates the config file in `init/1`. Stores the parsed config and the file's mtime in GenServer state. If any quick actions were missing `id` fields, the file is rewritten immediately with the generated IDs — this ensures IDs are stable across reloads and cached by API clients (e.g., the Android app). Starts a periodic mtime check via `Process.send_after/3`.
- **File change detection**: Every 2 seconds (`config_poll_interval`, configurable), the GenServer checks the config file's mtime via `File.stat/1`. If the mtime has changed, it re-reads and re-parses the file, updates state, and broadcasts `{:config_changed, config}` on PubSub topic `"config"`. This catches manual YAML edits without needing a filesystem watcher dependency.
- **Reads**: `Config.get/0` makes a `GenServer.call` returning the in-memory config. Fast — no file I/O.
- **Writes**: `Config.update/1` takes a function `(config -> config)`, applies it to the current state, writes to disk atomically (tmp + rename), updates mtime in state, and broadcasts `{:config_changed, config}` via PubSub. The mtime is updated from the freshly-written file's stat, so the next poll cycle won't trigger a redundant reload.
- **Validation**: On load, validate each quick action entry. Log warnings for invalid entries (missing `label`/`command`, unknown `color`) and skip them rather than crashing.
- **Missing file**: If no config file exists at startup, the GenServer writes the default config to disk (creating the parent directory via `File.mkdir_p!/1` if needed), then loads it into memory. This ensures a human-editable config file always exists for users to discover and customize.
- **Malformed file**: If the YAML is malformed on reload, `get/0` returns the last good config (still in GenServer state) and logs a warning. This is safer than the "fall back to defaults" approach — the user doesn't lose their action bar while fixing a typo.
- **Deleted file**: If the config file is deleted while the app is running, the GenServer keeps the last good config in memory. The poll cycle detects `mtime == nil` and skips reloading. The next `update/1` call will recreate the file on disk (via `mkdir_p` + write). This is intentional — deleting the file doesn't reset the running config.
- **Auto-creation on save**: `update/1` calls `File.mkdir_p!/1` on the parent directory before writing. If a user creates their first quick action via the Settings UI and no config file exists yet, it will be created automatically.
- **PubSub topic**: `"config"` — LiveViews subscribe on mount and update assigns on `{:config_changed, config}`.

```elixir
defmodule Termigate.Config do
  use GenServer
  require Logger

  @default_path "~/.config/termigate/config.yaml"

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

  def reorder_actions(ids) do
    # Pre-validate IDs before calling update to avoid silently writing
    # unchanged config on mismatch. Minor TOCTOU race is acceptable for
    # a single-user tool.
    config = get()
    known_ids = MapSet.new(config.quick_actions, & &1.id)
    requested_ids = MapSet.new(ids)

    if MapSet.equal?(known_ids, requested_ids) do
      update(&do_reorder_actions(&1, ids))
    else
      {:error, :id_mismatch}
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    path = config_path() |> Path.expand()
    poll_interval = Application.get_env(:termigate, :config_poll_interval, 2_000)
    {config, mtime} =
      case load_from_disk(path) do
        {:ok, config, ids_generated?, mtime} ->
          if ids_generated? do
            Logger.info("Generated missing IDs for quick actions — writing back to #{path}")
            case write_to_disk(path, config) do
              :ok -> {config, file_mtime(path)}
              {:error, _} -> {config, mtime}
            end
          else
            {config, mtime}
          end
        {:error, :malformed, mtime} ->
          Logger.warning("Config file at #{path} is malformed on startup — using defaults")
          {defaults(), mtime}
        {:error, :not_found} ->
          config = defaults()
          write_default_config(path, config)
          mtime = file_mtime(path)
          {config, mtime}
      end
    schedule_poll(poll_interval)
    {:ok, %{config: config, mtime: mtime, path: path, poll_interval: poll_interval}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:update, fun}, _from, state) do
    updated = fun.(state.config)
    case write_to_disk(state.path, updated) do
      :ok ->
        mtime = file_mtime(state.path)
        broadcast_change(updated)
        {:reply, {:ok, updated}, %{state | config: updated, mtime: mtime}}

      {:error, reason} ->
        Logger.error("Failed to write config to #{state.path}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:poll_config, state) do
    new_mtime = file_mtime(state.path)
    state =
      if new_mtime != state.mtime and new_mtime != nil do
        case load_from_disk(state.path) do
          {:ok, config, ids_generated?, mtime} ->
            {config, mtime} =
              if ids_generated? do
                Logger.info("Generated missing IDs for quick actions — writing back")
                case write_to_disk(state.path, config) do
                  :ok -> {config, file_mtime(state.path)}
                  {:error, _} -> {config, mtime}
                end
              else
                {config, mtime}
              end
            broadcast_change(config)
            %{state | config: config, mtime: mtime}

          {:error, :malformed, mtime} ->
            # Keep last good config in memory, update mtime to avoid re-reading
            # the same malformed file every poll cycle
            Logger.warning("Config file is malformed — keeping last good config")
            %{state | mtime: mtime}

          {:error, :not_found} ->
            state
        end
      else
        state
      end
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_poll(interval), do: Process.send_after(self(), :poll_config, interval)

  defp config_path, do: System.get_env("TERMIGATE_CONFIG_PATH") || @default_path

  defp load_from_disk(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} ->
        {config, ids_generated?} = parse(yaml)
        {:ok, config, ids_generated?, file_mtime(path)}
      {:error, %YamlElixir.ParsingError{}} -> {:error, :malformed, file_mtime(path)}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  defp write_to_disk(path, config) do
    yaml = to_yaml(config)
    tmp = path <> ".tmp"
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, yaml),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)  # clean up temp file on failure
        {:error, reason}
    end
  end

  defp write_default_config(path, config) do
    case write_to_disk(path, config) do
      :ok -> Logger.info("Created default config at #{path}")
      {:error, reason} -> Logger.warning("Could not create default config at #{path}: #{inspect(reason)}")
    end
  end

  defp broadcast_change(config) do
    Phoenix.PubSub.broadcast(Termigate.PubSub, "config", {:config_changed, config})
  end

  defp defaults, do: %{quick_actions: []}

  defp to_yaml(config) do
    data = %{
      "quick_actions" =>
        Enum.map(config.quick_actions, fn action ->
          %{
            "id" => action.id,
            "label" => action.label,
            "command" => action.command,
            "confirm" => action.confirm,
            "color" => action.color,
            "icon" => action.icon
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        end)
    }

    header = """
    # termigate configuration
    # Edit this file directly or use the web UI at /settings
    #
    # Quick actions appear as buttons above the terminal.
    # Fields: label (required), command (required), confirm, color, icon
    """

    header <> "\n" <> Ymlr.document!(data)
  end

  defp parse(yaml) do
    valid_entries =
      yaml
      |> Map.get("quick_actions", [])
      |> Enum.filter(&valid_action?/1)

    ids_generated? = Enum.any?(valid_entries, fn entry -> is_nil(entry["id"]) end)
    actions = Enum.map(valid_entries, &normalize_action/1)
    {%{quick_actions: actions}, ids_generated?}
  end

  defp valid_action?(%{"label" => l, "command" => c}) when is_binary(l) and is_binary(c), do: true
  defp valid_action?(entry) do
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
      icon: validate_icon(entry["icon"])
    }
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @valid_colors ~w(default green red yellow blue)
  defp validate_color(c) when c in @valid_colors, do: c
  defp validate_color(_), do: "default"

  @valid_icons ~w(rocket play stop trash arrow-up terminal)
  defp validate_icon(i) when i in @valid_icons, do: i
  defp validate_icon(_), do: nil

  # CRUD helpers (pure functions on config map)
  defp do_upsert_action(config, params) do
    action = normalize_action(params)
    actions = config.quick_actions
    case Enum.find_index(actions, &(&1.id == action.id)) do
      nil -> %{config | quick_actions: actions ++ [action]}
      idx -> %{config | quick_actions: List.replace_at(actions, idx, action)}
    end
  end

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
    Phoenix.PubSub.subscribe(Termigate.PubSub, "config")
  end

  config = Termigate.Config.get()

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
  # Return value intentionally ignored: if the pane is dead or no PaneStream
  # exists, the :pane_dead PubSub broadcast triggers the "Session ended"
  # overlay within milliseconds, making a separate error flash redundant.
  # send_keys/2 looks up the PaneStream in the Registry and returns
  # {:error, :not_found} if none exists (no crash).
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

Add `yaml_elixir` (parser) and `ymlr` (encoder) to `server/mix.exs`:

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

- **YAML remains the source of truth**: The UI and API read from and write to `~/.config/termigate/config.yaml`. No database introduced.
- **Round-trip safe**: The YAML writer rewrites the file cleanly using `ymlr` (a YAML encoder library) with a header comment explaining the format. Comments in the original file are not preserved. Unknown top-level keys are also dropped — `to_yaml/1` only serializes known fields (`quick_actions`). This is acceptable since the structure is simple, the header documents the format, and new config sections will be added to `to_yaml/1` as they are implemented.
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
defmodule TermigateWeb.SettingsLive do
  use TermigateWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Termigate.PubSub, "config")
    end

    config = Termigate.Config.get()
    {:ok, assign(socket, :config, config)}
  end

  def handle_event("save_action", %{"action" => action_params}, socket) do
    case Termigate.Config.upsert_action(action_params) do
      {:ok, updated} -> {:noreply, assign(socket, :config, updated)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to save — check file permissions")}
    end
  end

  def handle_event("delete_action", %{"id" => id}, socket) do
    case Termigate.Config.delete_action(id) do
      {:ok, updated} -> {:noreply, assign(socket, :config, updated)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to delete — check file permissions")}
    end
  end

  def handle_event("reorder_actions", %{"ids" => ids}, socket) do
    case Termigate.Config.reorder_actions(ids) do
      {:ok, updated} -> {:noreply, assign(socket, :config, updated)}
      {:error, :id_mismatch} -> {:noreply, put_flash(socket, :error, "Quick actions changed — please refresh and try again")}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to reorder — check file permissions")}
    end
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
# termigate configuration
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

Extends the REST API with config endpoints:

```
GET    /api/config              — returns full config as JSON
GET    /api/quick-actions       — returns quick actions list
POST   /api/quick-actions       — add a new quick action (returns the full updated list including the new action with its generated id)
PUT    /api/quick-actions/:id   — update a quick action by stable id
DELETE /api/quick-actions/:id   — delete a quick action by stable id
PUT    /api/quick-actions/order — reorder quick actions (body: {"ids": ["id1","id2","id3"]})
```

**Why IDs, not list indices**: Index-based addressing is fragile — if two clients read the list and one deletes an item, the other client's indices become stale and would target the wrong action. Stable IDs (auto-generated random tokens via `Base.url_encode64`) prevent this.

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
defmodule TermigateWeb.QuickActionController do
  use TermigateWeb, :controller

  def index(conn, _params) do
    config = Termigate.Config.get()
    json(conn, %{quick_actions: config.quick_actions})
  end

  def create(conn, %{"action" => action_params}) do
    case Termigate.Config.upsert_action(action_params) do
      {:ok, updated} ->
        conn |> put_status(201) |> json(%{quick_actions: updated.quick_actions})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "Failed to write config: #{inspect(reason)}"})
    end
  end

  def update(conn, %{"id" => id, "action" => action_params}) do
    case Termigate.Config.upsert_action(Map.put(action_params, "id", id)) do
      {:ok, updated} -> json(conn, %{quick_actions: updated.quick_actions})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "Failed to write config: #{inspect(reason)}"})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Termigate.Config.delete_action(id) do
      {:ok, updated} -> json(conn, %{quick_actions: updated.quick_actions})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "Failed to write config: #{inspect(reason)}"})
    end
  end

  def reorder(conn, %{"ids" => ids}) do
    case Termigate.Config.reorder_actions(ids) do
      {:ok, updated} -> json(conn, %{quick_actions: updated.quick_actions})
      {:error, :id_mismatch} ->
        conn |> put_status(422) |> json(%{error: "ID list does not match existing quick action IDs"})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "Failed to write config: #{inspect(reason)}"})
    end
  end
end
```

#### Routes

```elixir
# router.ex

pipeline :require_auth_token do
  plug TermigateWeb.Plugs.RequireAuthToken
  # Reads bearer token from Authorization header, verifies via
  # Phoenix.Token.verify/4. Returns 401 with {"error": "unauthorized"}
  # on missing/invalid/expired token.
end

scope "/api", TermigateWeb do
  pipe_through :api

  post "/login", AuthController, :login  # rate limited via plug RateLimit, key: :login in AuthController
end

scope "/api", TermigateWeb do
  pipe_through [:api, :require_auth_token]

  get "/sessions", SessionController, :index
  post "/sessions", SessionController, :create  # rate limited via plug RateLimit, key: :session_create
  delete "/sessions/:name", SessionController, :delete
  put "/sessions/:name", SessionController, :update  # rename session
  post "/sessions/:name/windows", SessionController, :create_window
  post "/panes/:target/split", PaneController, :split
  delete "/panes/:target", PaneController, :delete

  get "/config", ConfigController, :show  # full config as JSON
  # Custom route before resources to avoid :id shadowing "order"
  put "/quick-actions/order", QuickActionController, :reorder
  resources "/quick-actions", QuickActionController, only: [:index, :create, :update, :delete]
end

scope "/", TermigateWeb do
  pipe_through :browser

  # Login page — outside authenticated scope so unauthenticated users can reach it.
  # AuthHook is NOT applied here. If the user is already authenticated,
  # AuthLive redirects to "/" on mount.
  live_session :unauthenticated do
    live "/login", AuthLive
  end
end

scope "/", TermigateWeb do
  pipe_through [:browser, :require_auth]
  # :require_auth is a no-op in localhost mode (no auth configured).
  # When auth is enabled (remote access), this protects all LiveViews.

  delete "/logout", AuthController, :logout

  live_session :authenticated, on_mount: [TermigateWeb.AuthHook] do
    live "/", SessionListLive
    live "/terminal/:target", TerminalLive
    live "/sessions/:session", MultiPaneLive  # redirects to active window
    live "/sessions/:session/windows/:window", MultiPaneLive
    live "/settings", SettingsLive
  end
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
| Scrollback limit | 1k-100k lines | 10k | `localStorage` | Note: this controls the xterm.js *client-side* scrollback buffer (how many lines the browser retains for scroll-up). It is independent of the server-side ring buffer and tmux's `history-limit`. |
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
TERMIGATE_AUTH_TOKEN="my-secret-token" _build/prod/rel/termigate/bin/termigate start
```

### Requirements

- tmux installed on the host (not bundled in the release)
- No database, no Redis, no external services
- Erlang/OTP runtime is bundled in the release (no system Erlang needed if `include_erts: true`)

### Systemd Service (optional)

```ini
[Unit]
Description=termigate
After=network.target

[Service]
Type=exec
User=ben
Environment=TERMIGATE_AUTH_TOKEN=<token>
Environment=HOME=/home/ben
ExecStart=/opt/termigate/bin/termigate start
ExecStop=/opt/termigate/bin/termigate stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Docker (alternative)

```dockerfile
FROM elixir:1.17-slim AS build  # Pin to match minimum Elixir version; bump as needed
# ... standard Phoenix Dockerfile ...

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y tmux && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server/_build/prod/rel/termigate /app
CMD ["/app/bin/termigate", "start"]
```

**Docker caveat**: The app needs access to the host's tmux server. Options:
1. Run tmux inside the container (limits usefulness — can't attach to host sessions)
2. Mount the host's tmux socket: `-v /tmp/tmux-$(id -u):/tmp/tmux-$(id -u)` — allows the container to talk to the host's tmux server
3. **Recommendation**: Native deployment (Mix release) is simpler for this use case since the app is inherently tied to the host's tmux

---

## Android App

### Overview

A native Android app (also named "termigate") that connects to the termigate server, providing a first-class terminal experience on Android devices. The app communicates via Phoenix Channels (WebSocket) for real-time terminal I/O and REST API for session management and configuration. It does **not** bundle or run tmux locally — the server is the source of truth for all terminal state.

**Domain**: `tmuxrm.tamx.org` (temporary — will change in the future)

### Tech Stack

| Component | Choice | Notes |
|-----------|--------|-------|
| Language | Kotlin | Coroutines for async I/O, modern Android standard |
| Min API | 26 (Android 8.0) | ~95% device coverage |
| UI toolkit | Jetpack Compose | Declarative UI for all non-terminal screens |
| Terminal renderer | Termux `terminal-emulator` library | Battle-tested VT100/xterm parser. Handles escape sequences, 256-color, scrollback, selection |
| Terminal view | Termux `TerminalView` (Android View) | Wrapped in Compose via `AndroidView` composable |
| WebSocket | OkHttp | Reliable, widely used, built-in reconnect support |
| Channel protocol | Thin Kotlin Phoenix Channel client | Implements Phoenix Channel JSON framing on top of OkHttp WebSocket. Libraries exist (e.g., `JavaPhoenixClient`) or can be written in ~200 lines — the protocol is simple |
| HTTP client | Ktor Client + kotlinx.serialization | REST API calls (sessions, quick actions, auth). Pure Kotlin, first-class kotlinx.serialization support via `ContentNegotiation` plugin, coroutine-native. Uses the OkHttp engine (`ktor-client-okhttp`) to share the OkHttp instance with the WebSocket layer. |
| DI | Hilt | Standard Android DI, integrates with ViewModel and Compose |
| Navigation | Compose Navigation | Type-safe routes between screens |
| Build | Gradle (Kotlin DSL) | Standard Android tooling |
| Testing | JUnit 5 + Espresso + Compose UI tests | Unit, integration, UI |
| Distribution | Google Play + F-Droid + Direct APK | All three from the start |

### Architecture

```
┌─────────────────────────────────────────────┐
│ Android App                                  │
│                                              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │ Session  │  │ Terminal  │  │ Settings  │ │
│  │ List     │  │ Screen    │  │ Screen    │ │
│  │ (Compose)│  │ (Compose) │  │ (Compose) │ │
│  └────┬─────┘  └────┬──────┘  └─────┬─────┘ │
│       │              │               │       │
│  ┌────┴─────┐  ┌────┴──────┐  ┌─────┴─────┐ │
│  │ Session  │  │ Terminal  │  │ Settings  │ │
│  │ ViewModel│  │ ViewModel │  │ ViewModel │ │
│  └────┬─────┘  └────┬──────┘  └─────┬─────┘ │
│       │              │               │       │
│  ┌────┴──────────────┴───────────────┴─────┐ │
│  │           Repository Layer               │ │
│  │  SessionRepo  TerminalRepo  ConfigRepo   │ │
│  └────┬──────────────┬───────────────┬─────┘ │
│       │              │               │       │
│  ┌────┴─────┐  ┌────┴──────┐  ┌─────┴─────┐ │
│  │ REST API │  │ Phoenix   │  │ REST API  │ │
│  │ Client   │  │ Channel   │  │ Client    │ │
│  │ (Ktor)   │  │ Client    │  │ (Ktor)    │ │
│  └──────────┘  └───────────┘  └───────────┘ │
│                      │                       │
└──────────────────────┼───────────────────────┘
                       │ WebSocket + HTTP
                       ▼
              termigate Server
```

#### Layer Responsibilities

- **Screens (Compose)**: Pure UI. Observe ViewModel state, emit user actions. No business logic.
- **ViewModels**: Hold UI state as `StateFlow`. Call repository methods. Handle navigation events.
- **Repositories**: Abstract server communication. Expose suspend functions and Flows. Handle caching, retry, error mapping.
- **Network clients**: Raw HTTP and WebSocket communication. Serialization/deserialization. No business logic.

### Screens

#### Login Screen

- Username and password fields (pre-filled username from last login, stored in preferences)
- "Connect" button → POST `/api/login` with credentials
- On success: store bearer token in EncryptedSharedPreferences, navigate to session list
- On failure: show error message, stay on login screen
- Server URL field (stored in preferences): `https://host:port` — the user configures this once
- "Remember me" toggle (default: on) — controls whether the token is persisted across app restarts

#### Session List Screen

- Joins the `"sessions"` Channel topic on screen entry — receives the current session list in the join reply and real-time `"sessions_updated"` pushes thereafter
- Each session is a card showing: session name, window count, created time, attached status
- Expanding a session card shows its panes (pane index, dimensions, running command)
- Tap a pane → navigate to Terminal Screen with `session:window.pane` target
- "New Session" FAB → bottom sheet with name input and optional command
- Session action menu (long-press or kebab icon): rename session, create window, kill session (with confirmation)
- Rename session: inline edit dialog with name validation → `PUT /api/sessions/:name`
- Create window: `POST /api/sessions/:name/windows`
- Pane action menu (long-press on pane within expanded session card): split horizontal, split vertical, kill pane
- Split pane: `POST /api/panes/:target/split` with direction → navigates to the new pane on success
- Swipe-to-delete on sessions (with confirmation dialog) → `DELETE /api/sessions/:name`
- **Pull-to-refresh**: Calls `GET /api/sessions` as a fallback (e.g., if the Channel is momentarily disconnected). Under normal operation, the Channel push keeps the list current without polling.
- Leaves the `"sessions"` topic when navigating away from the screen

#### Terminal Screen

The primary screen. Full-screen terminal with an action bar overlay.

```
┌──────────────────────────────┐
│ ← session:0.0         [⚙]   │  ← top bar (auto-hides after 3s)
├──────────────────────────────┤
│ [Status] [Push ⚠] [Tests] ► │  ← quick action bar (scrollable)
├──────────────────────────────┤
│                              │
│  $ echo "hello"             │
│  hello                       │
│  $                           │
│                              │
│                              │
├──────────────────────────────┤
│ [Esc][Tab][Ctrl][Alt][↑↓←→]  │  ← special key toolbar
└──────────────────────────────┘
```

**Layout**:
- Top bar: back arrow, session/pane target label, settings gear icon. Auto-hides after 3 seconds of inactivity. Tap top edge to reveal.
- Quick action bar: horizontally scrollable buttons, same styling as web (color-coded pills, `⚠` for confirm actions). Only shown if quick actions are configured. Collapsible via chevron.
- Terminal view: fills remaining space. Termux `TerminalView` wrapped in Compose `AndroidView`.
- Special key toolbar: fixed at bottom. Same key set as web mobile toolbar: `Esc`, `Tab`, `Ctrl` (sticky), `Alt` (sticky), arrow keys, `Paste`. Swipe up for extended keys (F1-F12, PgUp/PgDn, Home/End).

**Lifecycle**:
1. On screen entry: join Phoenix Channel topic `"terminal:{session}:{window}:{pane}"` with auth token
2. Channel join reply provides `history` (raw bytes), `cols`, `rows`
3. Feed history bytes into Termux terminal emulator → renders on `TerminalView`
4. Channel `"output"` events → feed raw bytes into terminal emulator (streaming)
5. Keyboard input → convert to terminal byte sequences → send via Channel `"input"` event
6. Special key toolbar taps → emit corresponding escape sequences/control codes via Channel `"input"`
7. Quick action tap → send command + `\n` as bytes via Channel `"input"` (with confirmation dialog if `confirm: true`). No client-side size validation needed — quick action commands are user-configured strings (typically a few hundred bytes). The server enforces the 128KB limit on all Channel `"input"` events, which covers all input paths including quick actions.
8. Channel `"pane_superseded"` event → leave the current topic, convert `new_target` (e.g., `"new-name:0.1"`) to Channel topic format (`"terminal:new-name:0:1"`), rejoin under the new topic. The rejoin provides fresh history — clear the terminal emulator and re-render. The user sees a brief reload, same as the web redirect.
9. On screen exit: leave the Channel topic (server auto-unsubscribes via monitor)

**Terminal rendering integration**:

```kotlin
// Simplified — actual implementation wraps Termux library types
class TerminalSession(
    private val channel: PhoenixChannel,
    cols: Int,
    rows: Int
) : TerminalOutput {

    val emulator = TerminalEmulator(this, cols, rows, /* scrollback */ 10000)

    // Called by Channel "output" handler
    fun onServerOutput(bytes: ByteArray) {
        emulator.append(bytes, bytes.size)
        // TerminalView observes emulator state and re-renders
    }

    // TerminalOutput interface — called by emulator when it needs to
    // send data back (e.g., terminal query responses like cursor position)
    override fun write(data: ByteArray, offset: Int, count: Int) {
        // Sends as a binary WebSocket frame (V2 format) — not JSON
        channel.pushBinary("input", data.sliceArray(offset until offset + count))
    }
}
```

**Screen orientation**: The Terminal Screen allows both portrait and landscape (auto-rotate). Landscape is valuable for terminal work (more columns). Compose + ViewModel ensures UI state survives configuration changes. The Termux `TerminalView` (traditional Android View) must explicitly save and restore its state across configuration changes — the `TerminalEmulator` instance is held in the ViewModel (not the View), so the View reconnects to the same emulator after rotation. The Channel connection lives in the repository layer and is unaffected by UI configuration changes.

**TerminalView + Compose lifecycle**: Wrapping Termux's `TerminalView` in Compose's `AndroidView` requires explicit focus management — the `TerminalView` needs `requestFocus()` on first composition and after returning from other screens (e.g., Settings), otherwise keyboard input may not reach the terminal. The `AndroidView`'s `update` callback should handle re-binding the `TerminalView` to the current `TerminalEmulator` instance from the ViewModel. The `TerminalView`'s lifecycle is tied to the Compose composition, not the Activity — this is correct for the single-screen navigation model, but means the View is destroyed and recreated on navigation (the emulator state in the ViewModel persists).

**Keyboard input handling**:

The Android soft keyboard produces `KeyEvent`s and `InputConnection` text. The Termux `TerminalView` handles the translation from Android input methods to terminal byte sequences (including IME composition for non-Latin scripts, hardware keyboard support, and modifier key combos). The resulting bytes are sent to the server via the Channel `"input"` event.

For the special key toolbar, each button directly emits the appropriate byte sequence:
- `Esc` → `\x1b`
- `Tab` → `\x09`
- `Ctrl` + key → bitwise AND with `0x1f` (e.g., Ctrl+C → `\x03`)
- Arrow keys → ANSI escape sequences (`\x1b[A`, `\x1b[B`, etc.)
- F1-F12 → corresponding escape sequences

#### Settings Screen

- Server URL configuration
- Quick actions management (mirrors web Settings UI):
  - List of configured quick actions with edit/delete
  - Add new quick action (label, command, confirm toggle, color picker)
  - Drag-to-reorder
  - Synced via REST API (`/api/quick-actions` endpoints)
- Display preferences (stored locally in SharedPreferences):
  - Font size (pinch-to-zoom also works in terminal)
  - Color scheme / theme
  - Keep screen on (toggle — prevents screen timeout during terminal use)
  - Vibrate on special keys (haptic feedback toggle)
- Connection preferences:
  - Session list auto-refresh interval
  - Auto-reconnect behavior

### Connection Management

#### Phoenix Channel Client

A thin Kotlin implementation of the Phoenix Channel protocol on top of OkHttp WebSocket:

```kotlin
class PhoenixSocket(
    private val url: String,
    private val params: Map<String, String>,  // {"token": "..."}
    private val client: OkHttpClient
) {
    // Connection state as StateFlow for Compose observation
    val connectionState: StateFlow<ConnectionState>

    fun connect()
    fun disconnect()
    fun channel(topic: String): PhoenixChannel
}

class PhoenixChannel(
    private val socket: PhoenixSocket,
    val topic: String
) {
    val events: Flow<ChannelEvent>  // Collect to receive server pushes

    suspend fun join(payload: Map<String, Any> = emptyMap()): JoinResult
    suspend fun leave()
    suspend fun push(event: String, payload: Map<String, Any>): PushResult     // JSON text frame
    suspend fun pushBinary(event: String, payload: ByteArray): PushResult       // V2 binary frame
}
```

**Protocol details**:
- **Text frames** (JSON): `[join_ref, ref, topic, event, payload]` JSON array — used for control messages, join/leave, heartbeat, and replies
- **Binary frames** (V2 format): same header layout as described in "Binary Frames on Phoenix Channel" (Bandwidth Optimization section) — used for terminal data (`output`, `reconnected`, `input`)
- Heartbeat: send `"heartbeat"` every 30 seconds to keep the WebSocket alive
- Join: send `"phx_join"` event (text frame), wait for `"phx_reply"` with `"ok"` or `"error"` status
- Push: send event with auto-incrementing `ref`, match reply by `ref`
- Server push: events with `null` ref — dispatched to channel event Flow

**Binary frame handling**: OkHttp distinguishes frame types via separate callbacks: `onMessage(webSocket, text: String)` for JSON text frames and `onMessage(webSocket, bytes: ByteString)` for binary frames. The Kotlin client parses the binary header (three 1-byte length prefixes for join_ref, topic, and event, followed by the strings and then the raw payload) to extract the event name and payload bytes. This is ~20 lines of parsing code. Client-to-server binary frames use the same header format.

#### Reconnection Strategy

Network drops are common on mobile. The app must handle them gracefully:

1. **WebSocket disconnect detected**: OkHttp `onFailure`/`onClosed` callback fires
2. **Exponential backoff reconnect**: 1s → 2s → 4s → 8s → 16s → 30s (cap). Reset on successful connect.
3. **On reconnect**: Re-authenticate (token may have expired). If token is valid, re-join all active Channel topics.
4. **Channel rejoin**: Server sends fresh history in the join reply. App clears the terminal emulator and re-renders from the new history. This matches the web app's reconnection behavior.
5. **UI feedback**: Show a subtle "Reconnecting..." indicator in the terminal top bar. Transition to "Connected" on success. If reconnection fails after 5 minutes of attempts, show a "Connection lost" screen with a manual "Retry" button.

**Foreground service**: While a terminal session is active, run a foreground service with a persistent notification ("Connected to session-name:0.0"). This prevents Android from killing the app during background use and gives the user a quick way to return to the terminal. The service is started when the first `TerminalChannel` topic is joined and stopped when the last `TerminalChannel` topic is left (i.e., the user navigates away from all Terminal Screens). The `SessionChannel` does not count — browsing the session list does not require a foreground service. If multiple terminal sessions are open, the notification shows the count (e.g., "Connected to 3 sessions").

#### Token Management

- Token stored in `EncryptedSharedPreferences` (Android Keystore-backed)
- Token TTL matches server config (`auth_session_ttl_days`, default 30 days)
- On 401/token rejection: clear stored token, navigate to Login Screen
- Token refresh: no explicit refresh mechanism — the user re-authenticates when the token expires (same as web session expiry). For a 30-day TTL, this is infrequent.

#### TLS and Certificate Verification

The Android app uses standard TLS certificate verification (Android's default trust store) — no certificate pinning or trust-on-first-use (TOFU). Rationale:

- **Tailscale/VPN is the recommended deployment** for personal use, which eliminates public TLS entirely.
- **TOFU is deceptively complex**: legitimate cert rotations (Let's Encrypt renews every 90 days) would trigger false alarms, requiring a cert store, user prompts, and override UI.
- **Certificate pinning is brittle**: pins break on renewal unless pinning the CA or public key, adding configuration burden for a minimal-setup tool.
- **Standard TLS is sufficient** for the threat model. Users exposing the server to the internet use HTTPS with a real cert (Let's Encrypt, Caddy auto-TLS). Compromised CAs are a catastrophic scenario that per-app pinning won't meaningfully mitigate.

For maximum security on untrusted networks, users should deploy behind Tailscale or a WireGuard VPN rather than relying on public TLS alone.

### Resize Behavior

The Android app follows the **passive resizer** pattern described in the web mobile UI section:

- On Channel join, read pane dimensions from the join reply (`cols`, `rows`)
- Configure the terminal emulator with those dimensions
- Do **not** send resize events when the Android viewport changes (soft keyboard open/close, rotation)
- Instead, scale the terminal view to fit the available space via font size adjustment or scrolling
- Optional "Fit to screen" button: calculates the cols/rows that would fill the current viewport, sends a `"resize"` Channel event (with confirmation since it affects other viewers)
- When receiving `"resized"` events from the server (another viewer resized): reconfigure the terminal emulator with the new dimensions and re-render

### Clipboard Integration

- **Copy**: Long-press on the terminal triggers text selection (Termux `TerminalView` handles this natively). Selected text is copied to the Android clipboard via `ClipboardManager`.
- **Paste**: "Paste" button in the special key toolbar reads from `ClipboardManager` and sends the text as bytes via Channel `"input"` event. Also supports the standard Android paste gesture (long-press → paste from context menu) if Termux's `TerminalView` supports it.
- **No HTTPS requirement**: Unlike the web app's Clipboard API, Android's `ClipboardManager` works without HTTPS.

### Notification Support

- **Foreground service notification**: Persistent while connected (see Connection Management)
- **Pane death notification**: When a `"pane_dead"` event is received while the app is in the background, show a system notification: "Session ended: session-name:0.0". Tap navigates to the session list.
- **Connection lost notification**: If the WebSocket disconnects and cannot reconnect after 60 seconds while in the background, notify the user.

### Offline Behavior

The app is online-only by nature (it's a remote terminal client). Offline handling:

- **Session list**: Cache the last-fetched session list in memory. Display it immediately on screen entry, then refresh from the server. If the server is unreachable, show the cached list with a "Server unreachable" banner.
- **Quick actions**: Cache in plain `SharedPreferences` after each fetch (not sensitive data — commands are user-configured, not secrets). Available immediately on app start, synced when the server is reachable. Auth tokens use `EncryptedSharedPreferences` — see Token Management.
- **Terminal**: No offline mode. If the WebSocket is disconnected, show "Reconnecting..." with the reconnection strategy described above.

### Project Structure

```
android/
  app/
    src/main/
      java/org/tamx/tmuxrm/
        di/                          # Hilt modules
          NetworkModule.kt           # OkHttpClient, Ktor HttpClient providers
          AppModule.kt               # Repository bindings
        data/
          network/
            PhoenixSocket.kt         # WebSocket + Channel protocol
            PhoenixChannel.kt        # Single channel abstraction
            ApiClient.kt             # Ktor HttpClient wrapper for REST API calls
            AuthPlugin.kt            # Ktor plugin: adds bearer token to API requests
          repository/
            SessionRepository.kt     # Session list via SessionChannel + CRUD via REST API
            TerminalRepository.kt    # Channel join/leave, input/output
            ConfigRepository.kt      # Quick actions CRUD via REST API
            AuthRepository.kt        # Login, token storage
          model/
            Session.kt               # Session/Pane data classes
            QuickAction.kt           # Quick action data class
        ui/
          login/
            LoginScreen.kt           # Compose UI
            LoginViewModel.kt
          sessions/
            SessionListScreen.kt     # Compose UI
            SessionListViewModel.kt
          terminal/
            TerminalScreen.kt        # Compose UI with AndroidView for TerminalView
            TerminalViewModel.kt
            TerminalSession.kt       # Bridges Channel ↔ Termux emulator
            SpecialKeyToolbar.kt     # Compose toolbar component
            QuickActionBar.kt        # Compose quick action bar
          settings/
            SettingsScreen.kt        # Compose UI
            SettingsViewModel.kt
          navigation/
            AppNavigation.kt         # Compose Navigation graph
          theme/
            Theme.kt                 # Material 3 theme
            Color.kt
        service/
          TerminalForegroundService.kt  # Foreground service for background connection
        App.kt                       # Application class (Hilt entry point)
      res/
        values/
          strings.xml
          themes.xml
    src/test/                        # Unit tests (JUnit 5)
    src/androidTest/                 # Instrumented tests (Espresso + Compose)
  build.gradle.kts
  terminal-lib/                      # Forked Termux terminal-emulator + terminal-view
    src/main/java/
      com/termux/terminal/           # TerminalEmulator, TerminalBuffer, etc.
      com/termux/view/               # TerminalView, TerminalRenderer
    build.gradle.kts                 # Android library module
  build.gradle.kts                   # Root build file
  settings.gradle.kts                # includes :app, :terminal-lib
  gradle/
    libs.versions.toml               # Version catalog
```

### Build & Distribution

#### Build Variants

```kotlin
// build.gradle.kts
android {
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // proguard-rules.pro must include keep rules for:
            // - OkHttp (ships its own rules via META-INF, but verify)
            // - kotlinx.serialization (@Serializable data classes, serializers)
            // - Ktor (client engine, content negotiation plugin)
            // - Termux terminal-emulator (JNI and reflection if used)
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }
}
```

#### Distribution Channels

1. **Google Play**: Standard release via Android App Bundle (AAB). Signed with upload key, Google manages distribution key.
2. **F-Droid**: Reproducible builds required. All dependencies are open source (Termux terminal-emulator is Apache 2.0, OkHttp is Apache 2.0, Jetpack libraries are Apache 2.0). No proprietary dependencies (no Google Play Services, no Firebase, no proprietary analytics). F-Droid metadata in `metadata/android/en-US/` directory (fastlane format). Build recipe in `fdroid/org.tamx.tmuxrm.yml`.
3. **Direct APK**: Signed APK published as a GitHub Release artifact. CI builds and attaches the APK on each tagged release. Users can download and sideload.

#### CI/CD (GitHub Actions)

```yaml
# Triggered on push to main and tags
- Build debug APK (every push)
- Run unit tests + instrumented tests (every push)
- Build release APK + AAB (on tag)
- Sign release artifacts (on tag)
- Create GitHub Release with APK attached (on tag)
- Upload AAB to Google Play internal track (on tag, optional)
```

### Resolved Decisions

#### Termux Library Integration

**Decision**: Fork the `terminal-emulator` and `terminal-view` modules into a local Gradle module within this repository at `android/terminal-lib/`. The app module depends on it via `implementation(project(":terminal-lib"))`. No separate repo, no published package — everything builds together. The Termux code is stable and changes infrequently, so maintaining the fork in-tree is low effort. Updates are done by copying updated source files from the Termux repo as needed.

#### Phoenix Channel Client

**Decision**: Write our own minimal Kotlin implementation (~200 lines) on top of OkHttp WebSocket. The Phoenix Channel protocol is simple JSON framing — well-documented, easy to test, and avoids dependency on unmaintained third-party libraries.

#### Feature Scope

**All features ship in v1** — no phased rollout. The full feature set:
- Connect to server, authenticate
- List sessions and panes
- Create/kill/rename sessions
- Create windows, split panes (horizontal/vertical), kill panes
- Open a terminal session (stream output, send input)
- Special key toolbar (Esc, Tab, Ctrl, Alt, arrows, F1-F12, PgUp/PgDn, Home/End)
- Quick action buttons (read and CRUD management)
- Settings management (quick actions, display preferences)
- Reconnection on network drop
- Copy/paste
- Foreground service + notifications (pane death, connection lost)
- Font size / theme customization
- Haptic feedback preferences

#### Hardware Keyboard Support

**Decision**: Use Termux's built-in hardware keyboard handling. It correctly maps Ctrl+key, function keys, Alt combos, and other special key combinations. Battle-tested by millions of Termux users. Custom key mappings can be layered on later if users request them.

#### App Name and Package ID

- **App name**: termigate
- **Package ID**: `org.tamx.tmuxrm`
- **Domain**: `tmuxrm.tamx.org` (temporary — will change)
- **Icon design**: TBD

## Implementation Order

Suggested build order based on dependencies and incremental progress:

| Order | Feature | Effort | Notes |
|-------|---------|--------|-------|
| 1 | Core terminal (list, create, stream, input, pane death) | Large | Foundation — everything else builds on this |
| 2 | Auth + remote access | Medium | Required for mobile use |
| 3 | Pane resize sync | Small | Quality-of-life, simple once core is working |
| 4 | Session management (kill, rename) | Small | Basic lifecycle control |
| 5 | Quick actions (command buttons) | Small | High-value for mobile; introduces Config GenServer |
| 6 | User preferences (font, theme) | Small | Client-side only, no server changes |
| 7 | Phoenix Channel (server-side) | Medium | TerminalChannel + UserSocket — prerequisite for Android |
| 8 | Android app | Large | Full app: auth, sessions, terminal, quick actions, settings, notifications |
| 9 | Multi-pane split view (web) | Medium | Complex layout logic |

