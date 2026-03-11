# Phase 11: Phoenix Channels (Server-Side for Native Clients)

## Goal
Implement `TerminalChannel` and `SessionChannel` — the server-side Channel infrastructure for native Android (and any future non-web) clients. These channels use the same PaneStream/PubSub backend as LiveView but expose a raw WebSocket protocol with binary frame support. After this phase, the server is ready for native client connections.

## Dependencies
- Phase 3 complete (PaneStream)
- Phase 4 complete (SessionPoller)
- Phase 6 complete (UserSocket with token auth)

**Note**: The core `TerminalChannel` (join, output push, input handler, PaneStream subscription) is built in Phase 5 as part of the hybrid LiveView + Channel architecture. This phase extends it with any missing native-client-specific features (e.g., resize handling differences) and adds `SessionChannel`. Do NOT re-create TerminalChannel from scratch — build on the Phase 5 implementation.

## Steps

### 11.1 TerminalChannel

**`lib/tmux_rm_web/channels/terminal_channel.ex`**:

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
- `{:pane_output, _target, data}` → push binary frame: `{:push, {:binary, data}, socket}` (see 11.4 for binary frame details)
- `{:pane_dead, _target}` → push JSON: `push(socket, "pane_dead", %{})`
- `{:pane_superseded, _old, new_target}` → push JSON: `push(socket, "pane_superseded", %{"new_target" => new_target})`
- `{:pane_resized, cols, rows}` → push JSON: `push(socket, "resized", %{"cols" => cols, "rows" => rows})`
- `{:pane_reconnected, _target, buffer}` → push binary frame: `{:push, {:binary, buffer}, socket}` (see 11.4)
- `{:DOWN, ref, :process, _pid, _reason}` → PaneStream crashed. Re-subscribe, push fresh history via "reconnected", monitor new PID.

**`terminate/2`**:
- Call `PaneStream.unsubscribe(target)` (best-effort — monitor handles crashes)

### 11.2 SessionChannel

**`lib/tmux_rm_web/channels/session_channel.ex`**:

**Topic**: `"sessions"`

**`join/3`**:
1. Subscribe to PubSub topic `"sessions:state"`
2. Fetch current session list via `SessionPoller.get/0`
3. Reply `{:ok, %{"sessions" => sessions_json}}`

**`handle_info` callbacks**:
- `{:sessions_updated, sessions}` → compare to last-sent list, push `"sessions_updated"` if changed
- Store last-sent session list in socket assigns for diffing

**No client → server events**: Session mutations go through REST API.

### 11.3 UserSocket Channel Registration

Update `user_socket.ex`:
```elixir
channel "terminal:*", TmuxRmWeb.TerminalChannel
channel "sessions", TmuxRmWeb.SessionChannel
```

### 11.4 Binary Frame Support

Phoenix Channels use JSON text frames by default. To send raw binary terminal data efficiently, we use a **custom approach** since `push/3` only accepts map payloads:

**Approach**: Return `{:push, {:binary, data}, socket}` from `handle_info/2` to send raw binary WebSocket frames. This bypasses the Channel serializer entirely. The binary frame contains only the raw terminal bytes — no event name, no JSON wrapper. The client distinguishes binary frames (terminal data) from text frames (JSON control messages) by WebSocket opcode.

```elixir
# In TerminalChannel handle_info:
def handle_info({:pane_output, _target, data}, socket) do
  # Send as raw binary WebSocket frame
  {:push, {:binary, data}, socket}
end
```

**Important**: `{:push, {:binary, data}, socket}` is a valid return from `handle_info/2` in Phoenix Channels. It sends a raw binary WebSocket frame without Channel serialization. This is different from `push/3` which always serializes to JSON.

**For control messages** (resize, pane_dead, pane_superseded), use normal `push/3` with map payloads — these are sent as JSON text frames.

**Input from client**: Native clients send binary WebSocket frames for terminal input. The Channel receives these as `{:binary, bytes}` in `handle_in/3`:
```elixir
def handle_in("input", {:binary, bytes}, socket) do
  # bytes is raw binary, no base64 decoding needed
  PaneStream.send_keys(socket.assigns.target, bytes)
  {:noreply, socket}
end
```

**Alternative approach if `{:push, {:binary, ...}}` is not supported in your Phoenix version**: Use base64 encoding as a fallback: `push(socket, "output", %{"data" => Base64.encode64(data)})`. This adds 33% overhead but works with all Phoenix Channel versions. Test binary push support during Phase 5 implementation and choose accordingly.

Verify that `UserSocket` uses the default V2 serializer (do NOT override `@serializer`):
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

**`test/tmux_rm_web/channels/terminal_channel_test.exs`**:
- Join with valid target → receive history in reply
- Join with invalid target → error reply
- Send input → verify reaches tmux pane
- Receive output broadcast
- Pane death → receive `pane_dead` event
- PaneStream crash → receive `reconnected` event with fresh history

**`test/tmux_rm_web/channels/session_channel_test.exs`**:
- Join → receive current session list
- Create session externally → receive `sessions_updated` push
- Verify diffing (no push when list unchanged)

## Files Created/Modified
```
lib/tmux_rm_web/channels/terminal_channel.ex
lib/tmux_rm_web/channels/session_channel.ex
lib/tmux_rm_web/channels/user_socket.ex (update — register channels)
test/tmux_rm_web/channels/terminal_channel_test.exs
test/tmux_rm_web/channels/session_channel_test.exs
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

## Checklist
- [ ] 11.1 TerminalChannel
- [ ] 11.2 SessionChannel
- [ ] 11.3 UserSocket Channel Registration
- [ ] 11.4 Binary Frame Support
- [ ] 11.5 Channel-Specific Behaviors
- [ ] 11.6 Tests
