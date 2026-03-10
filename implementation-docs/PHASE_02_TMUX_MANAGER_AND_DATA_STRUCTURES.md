# Phase 2: TmuxManager & Data Structures

## Goal
Implement the stateless `TmuxManager` module that discovers, lists, and creates tmux sessions/panes, along with the supporting data structures (`Session`, `Pane`, `RingBuffer`). After this phase, the app can query tmux state and has the ring buffer ready for terminal streaming.

## Dependencies
- Phase 1 complete (CommandRunner behaviour + implementation, test infrastructure with Mox)

## Steps

### 2.1 Data Structures

**`lib/remote_code_agents/tmux/session.ex`** — Session struct:
```elixir
defmodule RemoteCodeAgents.Tmux.Session do
  defstruct [:name, :windows, :created, :attached?]
end
```

**`lib/remote_code_agents/tmux/pane.ex`** — Pane struct:
```elixir
defmodule RemoteCodeAgents.Tmux.Pane do
  defstruct [:session_name, :window_index, :index, :width, :height, :command, :pane_id]
end
```

### 2.2 TmuxManager Module

**`lib/remote_code_agents/tmux_manager.ex`** — stateless module (not a GenServer):

- `list_sessions/0` — shells out to `tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}'`, parses into `[%Session{}]`. Returns `{:ok, []}` if tmux returns "no server running" (exit code 1). Returns `{:error, :tmux_not_found}` if tmux binary missing.

- `list_panes/1` — takes a session name, runs `tmux list-panes -s -t {session} -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_width}\t#{pane_height}\t#{pane_current_command}\t#{pane_id}'`. The `-s` flag lists all panes across all windows in the target session (as opposed to `-a` which lists all panes in all sessions, making `-t` ineffective). Parses into a map of `%{window_index => [%Pane{}]}` grouped by window index.

- `create_session/1` — validates name against `^[a-zA-Z0-9_-]+$`. Runs `tmux new-session -d -s {name} [-x cols -y rows] [command]`. Broadcasts `{:sessions_changed}` on PubSub topic `"sessions:mutations"` on success. Returns `{:ok, session_info}` or `{:error, reason}`.

- `kill_session/1` — runs `tmux kill-session -t {name}`. Broadcasts `{:sessions_changed}` on PubSub topic `"sessions:mutations"` on success. Returns `:ok` or `{:error, reason}`.

- `session_exists?/1` — runs `tmux has-session -t {name}`, returns boolean.

- `rename_session/2` — validates new name, runs `tmux rename-session -t {old} {new}`. Broadcasts `{:sessions_changed}` on PubSub topic `"sessions:mutations"` on success.

- `create_window/1` — runs `tmux new-window -t {session}`. Broadcasts `{:sessions_changed}` on PubSub topic `"sessions:mutations"` on success.

- `split_pane/2` — runs `tmux split-window -h|-v -t {target}`. Returns new pane info. Broadcasts `{:sessions_changed}`.

- `kill_pane/1` — runs `tmux kill-pane -t {target}`. Broadcasts `{:sessions_changed}`.

All tmux commands go through the `CommandRunnerBehaviour` implementation (resolved via `Application.get_env(:remote_code_agents, :command_runner)`).

### 2.3 Session Name Validation

- Helper function `valid_session_name?/1` — checks `^[a-zA-Z0-9_-]+$`
- Used in `create_session/1` and `rename_session/2`
- Return `{:error, :invalid_name}` on failure

### 2.4 RingBuffer Module

**`lib/remote_code_agents/ring_buffer.ex`** — circular byte buffer:

- `new(capacity)` — creates a ring buffer with the given byte capacity. Default capacity is `ring_buffer_default_size` (2MB from Phase 1 config). Min/max bounds: `ring_buffer_min_size` (512KB) / `ring_buffer_max_size` (8MB).
- `append(buffer, binary)` — appends bytes, overwrites oldest data when full
- `read(buffer)` — returns a single contiguous binary (concatenating the two halves of the circular buffer)
- `size(buffer)` — returns current byte count

Implementation: use a fixed-size binary or `:array` with head/tail pointers. The key requirement is O(1) append and O(n) read where n is buffer size.

Suggested approach: store data as a list of binaries with a total byte count. On `read/1`, concatenate via `IO.iodata_to_binary/1`. On `append/2`, trim from the front if total exceeds capacity. This is simpler than a true circular buffer and performs well for the expected use case (write-heavy, read-infrequent).

### 2.5 Unit Tests

**`test/remote_code_agents/tmux_manager_test.exs`**:
- Use `Mox` with `MockCommandRunner` (set up in Phase 1) to return canned tmux output
- Test `list_sessions/0` parsing with various format strings
- Test `list_panes/1` parsing
- Test session name validation (valid names, invalid names with special chars)
- Test error cases (tmux not running, session doesn't exist)
- Test `create_session/1` PubSub broadcast

**`test/remote_code_agents/ring_buffer_test.exs`**:
- Test `new/1` creates empty buffer
- Test `append/2` + `read/1` round-trip
- Test overflow (append more than capacity, verify oldest data dropped)
- Test `size/1` accuracy
- Edge cases: empty read, single byte, exactly-capacity fill

## Files Created/Modified
```
lib/remote_code_agents/tmux/session.ex
lib/remote_code_agents/tmux/pane.ex
lib/remote_code_agents/tmux_manager.ex
lib/remote_code_agents/ring_buffer.ex
test/remote_code_agents/tmux_manager_test.exs
test/remote_code_agents/ring_buffer_test.exs
```

## Exit Criteria
- `TmuxManager.list_sessions/0` returns parsed session list from a running tmux
- `TmuxManager.create_session("test")` creates a session and broadcasts change
- `TmuxManager.list_panes("test")` returns pane details
- Session name validation rejects `"bad:name"`, `"bad.name"`, accepts `"good-name_1"`
- RingBuffer passes all unit tests (append, read, overflow, size)
- All unit tests pass with mocked CommandRunner
