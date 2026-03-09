# Design Review Findings

## Inconsistencies

### 1. Session poll interval conflict
Line 237 says "Default interval is 5 seconds" but line 581 says "polling fallback in `SessionListLive` (every 3s)". Pick one.

### 2. `capture-pane` flags
Line 141 uses `-p -e -S -` but line 592 doesn't mention `-e`. The `-e` flag means the ring buffer stores ANSI-escaped output, which affects buffer sizing estimates (line 189 acknowledges this but calls it "rough"). Worth being explicit that history always includes escape sequences.

### 3. PaneStream shutdown after death
Line 109 says "shut down after viewers acknowledge/disconnect" but line 330 says "terminates after a short delay". These are different strategies — one waits for viewers, the other uses a timer. Which is it?

### 4. Grace period interaction with pane death
Line 108 describes the grace period for zero viewers, but there's no mention of what happens when a pane dies AND has zero viewers — does the grace period apply, or does it shut down immediately? The dead-pane flow (lines 325-331) doesn't interact with the grace period logic.

### 5. `subscribe/1` race condition
Line 103 says `subscribe/1` starts a PaneStream if not found, but what if two viewers call `subscribe/1` simultaneously for the same target? `DynamicSupervisor.start_child` could race. The design should specify handling `{:error, {:already_started, pid}}` from `start_link`.

## Insufficiencies

### 6. No `tmux pipe-pane` cleanup on application crash
Line 179 says FIFO directory is cleared on startup, but stale `pipe-pane` attachments in tmux itself are not cleaned up at the application level. Only per-PaneStream init (line 174) detaches existing pipe-pane. If the app crashes and restarts but no one connects to a previously-streamed pane, that pane keeps its orphaned `pipe-pane` writing to a nonexistent FIFO. This is a slow resource leak in tmux.

### 7. No maximum concurrent PaneStreams
The DynamicSupervisor has no `max_children` specified. A misbehaving client could subscribe to every pane and exhaust resources (FIFOs, ports, memory).

### 8. FIFO path collision
Line 181 says targets like `mysession:0.1` are sanitized by replacing `:` and `.` with `-`. But session names allow hyphens (line 88), so `a-b:0.1` and `a:b-0.1` would both sanitize to `pane-a-b-0-1.fifo` — a collision. Use a separator character not in the allowed set (e.g., `_` or double-dash `--`).

### 9. Port exit vs pipe-pane detach ordering
In the shutdown sequence (line 167), pipe-pane is detached first (step 1), then the Port is closed (step 2). But detaching pipe-pane closes the write end of the FIFO, which causes `cat` to EOF and the Port to exit with `{:exit_status, 0}`. The GenServer would receive this message *during* shutdown, potentially triggering the pane-death flow (setting status to `:dead`, broadcasting). The shutdown sequence should handle this — either by ignoring port exits during intentional shutdown or by closing the port first.

### 10. No `send-keys` command length limit
Bulk paste (line 227) sends all bytes in a single `tmux send-keys -H` call. Very large pastes could exceed OS argument length limits (`ARG_MAX`, typically 2MB on Linux). Should document a chunking strategy.

### 11. Ring buffer `read/1` memory spike
Line 98 says `read/1` returns a single contiguous binary by concatenating. For a 4MB buffer, this allocates a 4MB binary on every new viewer connect. With multiple simultaneous connects, this could spike memory.

## Ambiguities

### 12. Session creation command escaping
"Optional starting command" for session creation (line 597) — how is this sent? As an argument to `tmux new-session -d -s {name} {command}`? If so, the command string needs shell escaping or should be passed as a list. No validation or escaping strategy is described.

### 13. PubSub subscription ownership
Line 103 says "PubSub subscription happens inside the GenServer call before history is returned, guaranteeing no messages are lost." But PubSub subscribes the *caller's PID*, not the GenServer's PID. If the subscription is done inside the GenServer call, `self()` is the GenServer, not the viewer. The design needs to clarify: does the GenServer forward messages, or does `subscribe/1` (the module function) subscribe the caller *before* making the GenServer call?

### 14. `terminate/2` and monitor double-unsubscribe
Line 263 says `terminate/2` calls `PaneStream.unsubscribe(target)`, but line 107 says PaneStream monitors viewer PIDs and auto-unsubscribes on crash. If `terminate/2` is called (normal shutdown), the monitor also fires. Is `unsubscribe` idempotent? It should be, but it's not stated.

### 15. xterm.js `onData` vs `onBinary`
Line 248 uses `onData` which emits JavaScript strings (UTF-16). For raw binary input (e.g., pasting binary content), `onData` may mangle bytes above U+FFFF. The design should state whether `onBinary` is needed or if `onData` + TextEncoder is sufficient for all cases.

## Minor Issues

### 16. Minimum version specificity
Technology table lists Elixir 1.17+ and OTP 27+ (line 405-406) — should specify exact minimum versions tested rather than open-ended ranges.

### 17. Missing `session_poll_interval` config entry
`session_poll_interval` config key (line 237) is not listed in the Configuration section (lines 498-527). Should be listed there.

### 18. Unknown icon name behavior
Heroicons subset for quick action icons (line 871) is limited. The design doesn't say what happens if an unknown icon name is specified — presumably ignored, but not stated.

---

## Priority

Most critical items (could cause bugs in production): **#5** (subscribe race), **#8** (FIFO name collision), **#9** (shutdown ordering), **#13** (PubSub subscription ownership).

Edge cases and documentation gaps: the rest.
