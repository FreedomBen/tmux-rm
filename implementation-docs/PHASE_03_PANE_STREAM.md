# Phase 3: PaneStream — Terminal Streaming Engine

## Goal
Implement the `PaneStream` GenServer — the heart of the application. This bridges tmux panes to viewers via `pipe-pane` + FIFO, manages the ring buffer, handles viewer lifecycle (subscribe/unsubscribe/grace period), and detects pane death. After this phase, the backend can stream terminal output and accept input for any tmux pane.

## Dependencies
- Phase 2 complete (TmuxManager, CommandRunner, RingBuffer)

## Steps

### 3.1 PaneStream GenServer

**`lib/remote_code_agents/pane_stream.ex`**:

#### State
```elixir
%{
  target: String.t(),           # "session:window.pane"
  pane_id: String.t(),          # tmux stable pane ID (e.g., "%0")
  pipe_port: port() | nil,
  viewers: MapSet.t(),
  buffer: RingBuffer.t(),
  status: :starting | :streaming | :dead | :shutting_down,
  grace_timer_ref: reference() | nil,
  port_recovery: %{attempts: non_neg_integer(), window_start: integer() | nil},
  coalesce_acc: iodata(),       # output coalescing accumulator
  coalesce_timer: reference() | nil,
  coalesce_bytes: non_neg_integer()
}
```

#### Registration
- Primary key: `{:pane, target}` via GenServer `name:` option using `{:via, Registry, {PaneRegistry, {:pane, target}}}`
- Secondary key: `{:pane_id, pane_id}` registered manually in `init/1` after resolving pane_id

#### Startup Sequence (async via `handle_continue`)
`init/1` sets status to `:starting` and returns `{:ok, state, {:continue, :setup}}` to avoid blocking the DynamicSupervisor. All I/O happens in `handle_continue(:setup, state)`:

0. Resolve `pane_id` via `tmux display-message -p -t {target} '#{pane_id}'`
0b. Register `{:pane_id, pane_id}` — handle collision (stale PaneStream detection, supersede flow)
1. Detach any existing pipe-pane: `tmux pipe-pane -t {pane_id}`
2. Remove stale FIFO: `File.rm(fifo_path)`
3. Create FIFO directory: `File.mkdir_p(fifo_dir)`
4. Create named pipe: `mkfifo -m 0600 {fifo_path}`
5. Start Port: `open_port({:spawn, "cat #{fifo_path}"}, [:binary, :stream, :exit_status])`
6. Attach pipe: `tmux pipe-pane -t {pane_id} -o 'cat >> #{fifo_path}'`
7. Query buffer size (history-limit × pane width, clamped to `ring_buffer_min_size`/`ring_buffer_max_size`)
8. Capture scrollback: `tmux capture-pane -p -e -S -{max_lines} -t {pane_id}`
9. Write scrollback into ring buffer
10. Set status to `:streaming`

If any step fails, set status to `:dead` and schedule termination.

**Note**: `subscribe/1` callers that arrive while status is `:starting` should receive `{:error, :not_ready}`. The caller can retry after a short delay (PaneStream startup typically completes in <100ms).

FIFO path: `/tmp/remote-code-agents/pane-{pane_id}.fifo` (e.g., `/tmp/remote-code-agents/pane-%0.fifo`)
Uses the resolved `pane_id` (not the target string) for stability across session/window renames. The `%` prefix in tmux pane IDs is filesystem-safe.

### 3.2 Public API (Module Functions)

- `subscribe/1` — called by viewer process:
  1. Subscribe caller to PubSub topic `"pane:#{target}"`
  2. Look up or start PaneStream via Registry + DynamicSupervisor
  3. `GenServer.call` to register viewer (monitor PID, add to MapSet)
  4. Return `{:ok, history :: binary(), pane_stream_pid :: pid()}` or `{:error, reason}`
     - `history` is always a single contiguous binary (from `RingBuffer.read/1` which returns `IO.iodata_to_binary/1`)
  5. On error, unsubscribe from PubSub before returning

- `unsubscribe/1` — called by viewer process:
  1. Look up PaneStream via Registry
  2. `GenServer.call` to remove viewer (demonitor, remove from MapSet)
  3. If no viewers remain, start grace period timer
  4. Idempotent — safe to call multiple times

- `send_keys/2` — called by viewer process:
  1. Look up PaneStream via Registry
  2. `GenServer.call` to send input
  3. GenServer handler: convert each byte to a two-char hex string, join with spaces, send as `tmux send-keys -H -t {pane_id} 41 42 43 ...` (space-separated hex values, no `0x` prefix)
  4. Chunk large inputs into sequential `send-keys` calls, each with at most 65,536 bytes (separate `CommandRunner.run/1` invocations, sent sequentially — not atomic)
  5. Return `:ok`, `{:error, :pane_dead}`, `{:error, :not_ready}`, or `{:error, :not_found}`

### 3.3 Output Handling (Coalescing)

**Algorithm**: Both timer-based and size-based coalescing. Defaults from config: `output_coalesce_ms: 3` (3ms timer), `output_coalesce_max_bytes: 32_768` (32KB size cap).

In `handle_info({port, {:data, bytes}})`:
1. Append bytes to IO list accumulator, increment `coalesce_bytes` counter
2. If `coalesce_bytes >= output_coalesce_max_bytes` (32KB), flush immediately (size-triggered)
3. If no coalesce timer active, start one: `Process.send_after(self(), :flush_output, output_coalesce_ms)` (timer-triggered)
4. On `:flush_output`: convert accumulator to binary via `IO.iodata_to_binary/1`, append to ring buffer, broadcast `{:pane_output, target, binary}` via PubSub, reset accumulator and `coalesce_bytes` to 0, clear timer ref

### 3.4 Viewer Lifecycle

- Monitor viewer PIDs via `Process.monitor/1`
- `handle_info({:DOWN, ref, :process, pid, _reason})` — auto-unsubscribe dead viewer
- Grace period: `Process.send_after(self(), :grace_period_expired, grace_period_ms)`
- On `:grace_period_expired`: re-check `MapSet.size(viewers) == 0`, then shut down if still empty
- New viewer during grace period: `Process.cancel_timer(grace_timer_ref)`

### 3.5 Pane Death Detection

- `handle_info({port, {:exit_status, 0}})` — pane died (normal EOF):
  - Cancel grace timer
  - Set status to `:dead`
  - Broadcast `{:pane_dead, target}` via PubSub
  - Clean up FIFO
  - Terminate normally (`{:stop, :normal, state}`)

- `handle_info({port, {:exit_status, n}})` where n > 0 — Port crash (pane may be alive):
  - Check pane existence via `tmux display-message -p -t {pane_id}`
  - If alive: pipeline recovery (new FIFO, new Port, re-attach pipe-pane), broadcast `{:pane_reconnected, target, buffer_binary}`
  - If dead or recovery fails: follow death path
  - Rate limit: max 3 recovery attempts per 60-second window

### 3.6 Shutdown Sequence

In `terminate/2`:
1. Flush any pending coalesce accumulator to ring buffer
2. Set status to `:shutting_down`
3. Detach pipe: `tmux pipe-pane -t {pane_id}`
4. Close Port
5. Remove FIFO

### 3.7 Supersede Flow

- On `{:superseded, new_target}` cast:
  1. Detach pipe-pane, clean up FIFO
  2. Broadcast `{:pane_superseded, target, new_target}` to viewers
  3. Terminate normally

### 3.8 PaneStreamSupervisor

**`lib/remote_code_agents/pane_stream_supervisor.ex`**:
- DynamicSupervisor with `max_children` from config
- `start_child/1` convenience function
- PaneStream children use `restart: :transient`

### 3.9 Integration Tests

**`test/remote_code_agents/pane_stream_test.exs`**:
- Start a real tmux session, subscribe to a pane, verify output arrives
- Send keys via `send_keys/2`, verify they reach the pane
- Test grace period (unsubscribe, wait, verify PaneStream terminates)
- Test pane death (kill tmux pane, verify `:pane_dead` broadcast)
- Test multiple viewers (subscribe two processes, verify both receive output)
- Test re-subscribe during grace period (cancel timer, PaneStream stays alive)

**`test/support/tmux_helpers.ex`**:
- `create_test_session/1` — creates a uniquely-named tmux session
- `destroy_test_session/1` — kills the session
- `setup_tmux/1` — ExUnit setup callback with `on_exit` cleanup

## Files Created/Modified
```
lib/remote_code_agents/pane_stream.ex
lib/remote_code_agents/pane_stream_supervisor.ex
test/remote_code_agents/pane_stream_test.exs
test/support/tmux_helpers.ex
```

## Exit Criteria
- PaneStream starts, attaches to a tmux pane, streams output to subscribers
- `send_keys/2` delivers input to the pane
- Grace period works (PaneStream lives beyond last unsubscribe, dies after timeout)
- Pane death detected and broadcast to viewers
- Port crash triggers pipeline recovery (when pane is alive)
- Ring buffer correctly stores scrollback + streaming output
- Output coalescing reduces broadcast frequency during high throughput
- Multiple viewers share a single PaneStream
- All integration tests pass (tagged `@tag :tmux`)
