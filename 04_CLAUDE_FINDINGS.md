# APPLICATION_DESIGN.md Review Findings

Review performed against the full design document. Issues with clear fixes have already been applied directly to APPLICATION_DESIGN.md. The items below require design decisions.

## Already Fixed

1. **Pane Death flow numbering** (was step 8, now step 6) — typo in port crash sub-flow
2. **`subscribe/1` missing error case** — added `{:error, :max_pane_streams}` to the interface docs
3. **`restart: :transient` vs port crash recovery conflation** — rewrote PaneStream crash recovery section to clearly distinguish GenServer crash (supervisor restart) from Port crash (in-process pipeline recovery)
4. **FIFO path shell injection safety** — added explicit safety trace from session name validation through percent-encoding to shell interpolation
5. **Grace period → fresh PaneStream** — documented that a subscribe after grace-period shutdown correctly re-runs full startup including scrollback capture
6. **Phase 1 resize behavior** — clarified that `handle_event("resize", ...)` stores dimensions but does not call `tmux resize-pane`
7. **LiveView crash recovery** — added note that Phoenix auto-reconnect re-runs `mount/3` which re-subscribes transparently
8. **`config.ex` in base project structure** — moved out of base structure, added "New Module" note under Quick Actions feature design

## Open Decisions

### D1: Large scrollback capture memory spike

`capture-pane -p -e -S -` could return a huge binary for panes with large `history-limit` (e.g., 500k lines ≈ 50MB). The entire capture is held in memory before being truncated into the ring buffer.

**Options:**
- **A) Accept**: The capture is transient, happens once per PaneStream startup, and frees quickly. Document as a known characteristic.
- **B) Mitigate**: Pass `-S -{N}` where N is `ring_buffer_capacity / pane_width` (estimated lines), so we only capture what the ring buffer can hold. Reduces peak memory from potentially 50MB to at most 4MB.

### D2: Output coalescing for high-throughput panes

Each `{:data, bytes}` from the Port triggers a separate PubSub broadcast and LiveView `push_event`. High-throughput output (e.g., `cat large_file`) could produce thousands of small pushes per second.

**Options:**
- **A) No coalescing**: LiveView's WebSocket batching and browser rendering handle this adequately. Document as a known characteristic.
- **B) Server-side coalescing**: Buffer output in PaneStream and flush on a timer (e.g., every 16ms), combining multiple Port messages into a single PubSub broadcast. Reduces push count at the cost of up to 16ms added latency.

### D3: Health check endpoint

No `/healthz` or equivalent is specified. Useful for systemd health checks and reverse proxy configurations.

**Options:**
- **A) Out of scope**: Not needed for Phase 1 localhost use.
- **B) Add**: Simple `GET /healthz` that returns 200 if the app is running and tmux is reachable (quick `tmux -V` or `tmux list-sessions` call). Minimal effort, useful for deployment.

### D4: `send_keys` chunking backpressure

For large pastes, multiple sequential `System.cmd` calls for `send-keys -H` chunks block the GenServer, preventing output processing during the paste.

**Options:**
- **A) Accept**: Large pastes are rare, and blocking briefly is fine for a single-user tool. Document the behavior.
- **B) Offload to Task**: Spawn a `Task` from the GenServer for chunked sends, so `handle_info` for Port data continues processing. Adds complexity for an edge case.

### D5: `TERM` environment variable for new sessions

When creating sessions via `tmux new-session`, the `TERM` value affects how programs render output. xterm.js expects `xterm-256color` semantics. Tmux normally sets this via its `default-terminal` option.

**Options:**
- **A) Leave to user's tmux config**: Most tmux installations default to `screen-256color` or `tmux-256color`, both compatible with xterm.js. Don't override.
- **B) Document the expectation**: Add a note that xterm.js assumes 256-color support and recommend users set `set -g default-terminal "tmux-256color"` in their tmux.conf. Don't force it programmatically.
- **C) Set explicitly**: Pass `TERM=xterm-256color` as an environment variable when creating sessions. Overrides user config, which may be undesirable.

### D6: tmux server restart / mass pane death

If the tmux server is killed/restarted, all PaneStream Ports EOF simultaneously. Each PaneStream follows its normal death path independently (set `:dead`, broadcast `:pane_dead`, terminate). Since `restart: :transient` doesn't restart normal exits, the supervisor won't restart any of them.

**Options:**
- **A) Document as handled**: The existing per-PaneStream death flow handles this correctly. Multiple simultaneous terminations are just multiple messages through DynamicSupervisor — no thundering herd since each child terminates independently (no supervisor restart). Add a brief note to the design.
- **B) Add detection**: Detect mass pane death (e.g., all PaneStreams die within a short window) and show a specific "tmux server unavailable" banner on the session list instead of per-pane "Session ended" messages. More work, better UX.
