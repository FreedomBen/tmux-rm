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

### D1: Large scrollback capture memory spike — RESOLVED (Option B)

`capture-pane` now uses `-S -{max_lines}` where `max_lines = ring_buffer_capacity / pane_width`, limiting the capture to what the ring buffer can hold. Applied to APPLICATION_DESIGN.md startup sequence step 7.

### D2: Output coalescing for high-throughput panes — RESOLVED (Option A)

No server-side coalescing. LiveView batches push_events per process turn, xterm.js batches rendering internally. Coalescing can be added later inside PaneStream without interface changes if profiling warrants it. Documented in APPLICATION_DESIGN.md data flow section.

### D3: Health check endpoint — RESOLVED (Option B)

Added `GET /healthz` endpoint. Unauthenticated, returns JSON with app and tmux status. Uses `CommandRunner.run(["list-sessions"])` to verify tmux reachability. Added to scope, project structure, and new Health Check Endpoint section in APPLICATION_DESIGN.md.

### D4: `send_keys` chunking backpressure — RESOLVED (Option A)

Accepted as-is. Documented the synchronous blocking behavior in the Performance section and noted that Task offloading is available as a future optimization. Applied to APPLICATION_DESIGN.md input handling section.

### D5: `TERM` environment variable for new sessions — RESOLVED (Option B)

Documented that xterm.js is compatible with `tmux-256color`, `screen-256color`, and `xterm-256color`. App does not override TERM — left to user's tmux config. Added recommendation to set `default-terminal "tmux-256color"` if rendering issues occur. Applied to Technology Choices table and new TERM note in APPLICATION_DESIGN.md.

### D6: tmux server restart / mass pane death — RESOLVED (Option A)

Documented as handled. Each PaneStream independently follows the normal death path, no supervisor restart cascade. SessionListLive polling shows the correct empty state. Added note to APPLICATION_DESIGN.md in the PaneStream lifecycle section.
