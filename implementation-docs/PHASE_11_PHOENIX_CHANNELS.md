# Phase 11: Phoenix Channels (Server-Side for Native Clients)

## Goal
Implement `TerminalChannel` and `SessionChannel` — the server-side Channel infrastructure for native Android (and any future non-web) clients. These channels use the same PaneStream/PubSub backend as LiveView but expose a raw WebSocket protocol with binary frame support. After this phase, the server is ready for native client connections.

## Dependencies
- Phase 3 complete (PaneStream)
- Phase 4 complete (SessionPoller)
- Phase 6 complete (UserSocket with token auth)

## Steps

### 11.1 TerminalChannel

**`lib/remote_code_agents_web/channels/terminal_channel.ex`**:

**Topic**: `"terminal:{session}:{window}:{pane}"` — client-facing join topic. Uses colons as separators because Phoenix Channel topics use `:` for namespacing.

**`join/3`**:
1. Parse topic into PaneStream target format `"session:window.pane"`: e.g., `"terminal:foo:0:1"` → `"foo:0.1"`. The canonical target format throughout the codebase is `"session:window.pane"` (colon between session and window, dot between window and pane). The Channel topic uses an extra colon only because Channel topics require the `"terminal:"` prefix for routing.
2. Call `PaneStream.subscribe/1` (same as TerminalLive)
3. Monitor returned `pane_stream_pid`
4. On success: reply `{:ok, %{"history" => base64_history, "cols" => cols, "rows" => rows}}`
   - History is base64 in the join reply (JSON text frame)
   - Cols/rows from `tmux display-message -p -t {pane_id} '#{pane_width} #{pane_height}'`
5. On error: reply `{:error, %{"reason" => "pane_not_found"}}` or `"max_pane_streams"`

**`handle_in` callbacks**:
- `"input"` with `{:binary, bytes}` — validate size ≤ 128KB, call `PaneStream.send_keys(target, bytes)`
- `"resize"` with `%{"cols" => c, "rows" => r}` — validate bounds (cols 1-500, rows 1-200), forward to PaneStream

**`handle_info` callbacks**:
- `{:pane_output, _target, data}` → push binary frame: `push(socket, "output", %{data: data})` (Phoenix V2 serializer auto-detects binary payloads in map values and sends as binary frames)
- `{:pane_dead, _target}` → push JSON: `push(socket, "pane_dead", %{})`
- `{:pane_superseded, _old, new_target}` → push JSON: `push(socket, "pane_superseded", %{"new_target" => new_target})`
- `{:pane_resized, cols, rows}` → push JSON: `push(socket, "resized", %{"cols" => cols, "rows" => rows})`
- `{:pane_reconnected, _target, buffer}` → push binary: `push(socket, "reconnected", %{data: buffer})` (binary payload auto-detected)
- `{:DOWN, ref, :process, _pid, _reason}` → PaneStream crashed. Re-subscribe, push fresh history via "reconnected", monitor new PID.

**`terminate/2`**:
- Call `PaneStream.unsubscribe(target)` (best-effort — monitor handles crashes)

### 11.2 SessionChannel

**`lib/remote_code_agents_web/channels/session_channel.ex`**:

**Topic**: `"sessions"`

**`join/3`**:
1. Subscribe to PubSub topic `"sessions"`
2. Fetch current session list via `SessionPoller.get/0`
3. Reply `{:ok, %{"sessions" => sessions_json}}`

**`handle_info` callbacks**:
- `{:sessions_updated, sessions}` → compare to last-sent list, push `"sessions_updated"` if changed
- Store last-sent session list in socket assigns for diffing

**No client → server events**: Session mutations go through REST API.

### 11.3 UserSocket Channel Registration

Update `user_socket.ex`:
```elixir
channel "terminal:*", RemoteCodeAgentsWeb.TerminalChannel
channel "sessions", RemoteCodeAgentsWeb.SessionChannel
```

### 11.4 Binary Frame Support

Phoenix's V2 JSON serializer handles binary frames automatically:
- Text frames: JSON for control messages (join, leave, heartbeat, replies)
- Binary frames: compact header + raw payload for data events

The Channel code uses `{:binary, bytes}` payloads for output/input events. The serializer handles frame type selection.

Verify that the V2 serializer is configured in `UserSocket`:
```elixir
use Phoenix.Socket
@impl true
def connect(params, socket, _connect_info) do
  # ... token verification ...
  {:ok, socket}
end

@impl true
def id(_socket), do: nil
```

### 11.5 Channel-Specific Behaviors

**Differences from LiveView**:
- Input: raw binary bytes, not base64 (Channel uses binary frames)
- Output: raw binary bytes, not base64
- History in join reply: base64 (JSON text frame exception)
- No LiveView push_event — uses Phoenix Channel `push/3`

**Shared with LiveView**:
- Same PaneStream backend
- Same PubSub topics
- Same subscribe/unsubscribe flow
- Same pane death / supersede handling

### 11.6 Tests

**`test/remote_code_agents_web/channels/terminal_channel_test.exs`**:
- Join with valid target → receive history in reply
- Join with invalid target → error reply
- Send input → verify reaches tmux pane
- Receive output broadcast
- Pane death → receive `pane_dead` event
- PaneStream crash → receive `reconnected` event with fresh history

**`test/remote_code_agents_web/channels/session_channel_test.exs`**:
- Join → receive current session list
- Create session externally → receive `sessions_updated` push
- Verify diffing (no push when list unchanged)

## Files Created/Modified
```
lib/remote_code_agents_web/channels/terminal_channel.ex
lib/remote_code_agents_web/channels/session_channel.ex
lib/remote_code_agents_web/channels/user_socket.ex (update — register channels)
test/remote_code_agents_web/channels/terminal_channel_test.exs
test/remote_code_agents_web/channels/session_channel_test.exs
```

## Exit Criteria
- `TerminalChannel`: join with topic, receive history, send input, receive output
- `SessionChannel`: join, receive session list, receive updates on changes
- Binary frames used for terminal data (output, input, reconnected)
- JSON frames used for control events (resize, pane_dead, pane_superseded)
- Token auth enforced on socket connect
- Rate limiting on WebSocket upgrade
- PaneStream crash recovery works via Channel (re-subscribe, push fresh history)
- Multiple channels can share a single PaneStream
- All channel tests pass
