# Implementation Phase Documents - Detailed Review

## Overall Assessment

The 14 phases are thorough, well-structured, and show clear architectural thinking. The FIFO/pipe-pane streaming design, the CommandRunner abstraction for testability, and the graceful PaneStream lifecycle are all well-considered. Below are the issues found.

---

## 1. Gaps Between Phases

### PubSub Message Name Mismatch
- **Phase 2** (TmuxManager) broadcasts `{:sessions_changed}` on topic `"sessions"`.
- **Phase 4** (SessionListLive) expects `{:sessions_updated, sessions}` on topic `"sessions"`.
- **Phase 4** (SessionPoller) also subscribes to `"sessions"` and handles `{:sessions_changed}` from TmuxManager, then re-broadcasts as `{:sessions_updated, sessions}`.
- This *works* but is fragile: both TmuxManager and SessionPoller broadcast on the same PubSub topic with different message shapes. If any LiveView accidentally handles `{:sessions_changed}` or any poller misses it, things break silently. **Recommendation**: Use separate PubSub topics (e.g., `"sessions:mutations"` for TmuxManager, `"sessions:state"` for SessionPoller) or document the dual-message design explicitly.

### LayoutPoller Not in Supervision Tree
- **Phase 1** defines the supervision tree with PaneStreamSupervisor but no LayoutPollerSupervisor.
- **Phase 12** introduces LayoutPoller under a DynamicSupervisor, but Phase 1's supervision tree doesn't include it. The LayoutPoller DynamicSupervisor must be added to `application.ex` retroactively. Phase 12 should explicitly state this.

### `list_panes/1` Uses `-a` Flag Incorrectly
- **Phase 2**: `list_panes/1` takes a session name and runs `tmux list-panes -t {session} -a`. The `-a` flag means "all sessions" which conflicts with `-t {session}`. You need either `-a` without `-t` (all panes across all sessions) or `-t {session}` without `-a` (panes for one session). The `-s` flag (all panes in a session across windows) is likely what's intended.

### Auth Live vs Auth Controller Overlap
- **Phase 6** defines both `AuthLive` (LiveView login page) and `AuthController` (REST API login). The `DELETE /logout` is on the AuthController, but the web login form is a LiveView. The router wiring in step 6.10 needs to carefully avoid conflicts. The logout action (which clears a session cookie) must be a regular HTTP request, not a LiveView event, which is correct, but this is easy to get wrong.

---

## 2. Missing Details

### Phase 3 - PaneStream `subscribe/1` Return Value
- The subscribe function is referenced everywhere but its exact return type is only partially documented. Phase 3.2 mentions it returns `{:ok, %{history: binary, pid: pid, cols: cols, rows: rows}}` but this is spread across multiple subsections. A single canonical type spec would prevent misinterpretation.

### Phase 5 - How TerminalLive Gets PaneStream PID for Monitoring
- Phase 5.3 says "Subscribe to PaneStream, get initial history" but doesn't explicitly show extracting and monitoring the PID from the subscribe response. Phase 3.2 documents this, but Phase 5 should reference it since crash recovery depends on it.

### Phase 6 - Credential File Permissions
- The credentials file stores a bcrypt hash but there's no mention of file permissions (should be 0600). A world-readable credentials file is a security issue.

### Phase 6 - `mix rca.setup` Not Fully Specified
- Step 6.2 mentions Mix tasks for setup and password change, but doesn't specify what happens if the credentials file already exists (overwrite? error? prompt?), or how the username is chosen.

### Phase 8 - Config File Schema
- The YAML config structure is referenced but never fully defined. What are all the top-level keys? What does the full default config look like? Only `quick_actions` is detailed.

### Phase 10 - No Server-Side Preference Sync
- Preferences are localStorage only. If a user logs in from a new device, they get defaults. This is documented as intentional (per-device), but there's no way to export/import preferences either.

### Phase 14 - No Reverse Proxy/TLS Guidance
- The deployment phase mentions HTTPS configuration "options" but doesn't provide concrete guidance for the most common deployment pattern (behind nginx/caddy with TLS termination). The CORS config in 14.8 implies reverse proxy use, but there's no example.

---

## 3. Ambiguities

### Phase 3 - Port Crash vs Pane Death Distinction
- `exit_status 0` = pane died, `exit_status > 0` = port crash. But `cat` on a FIFO returns 0 when the write end closes. If tmux's `pipe-pane` detaches (e.g., due to a tmux config reload), `cat` will get EOF (status 0), and the code will incorrectly treat it as pane death. The recovery logic should always check `session_exists?` / pane existence regardless of exit code.

### Phase 5 - Target Format Ambiguity
- Routes use `/terminal/{session}:{window}.{pane}` but the colon and dot in the target string could conflict with URL parsing. Phase 5.5 addresses this with a regex route but a developer might URL-encode the target. Should the target be passed as separate path segments instead?

### Phase 11 - Binary Frame Support
- Step 11.4 discusses binary frames for Phoenix Channels but the actual mechanism is vague: "Phoenix V2 serializer auto-detects binary payloads in map values." This is not how Phoenix binary frames work. Phoenix Channels send JSON by default; binary frames require explicit `{:binary, data}` handling at the transport level. This needs more precise implementation guidance.

### Phase 12 - MultiPaneLive vs TerminalLive Relationship
- Phase 12 introduces MultiPaneLive which seems to replace TerminalLive for sessions. But TerminalLive (Phase 5) handles single-pane viewing. Are both routes maintained? Phase 12.6 mentions "Single-Pane Navigation" but the routing overlap needs clarification.

---

## 4. Missing Error Handling

### Phase 3 - FIFO Creation Race Condition
- If two PaneStream processes try to start for the same pane simultaneously (before Registry can prevent it), both could attempt `mkfifo` on the same path. The Registry + `:via` registration should prevent this, but the startup sequence does resolution *then* registration, leaving a window.

### Phase 3 - `tmux pipe-pane` Failure
- Step 6 of the startup sequence (attach pipe) can fail silently if the pane was killed between step 0 and step 6. No explicit error check is documented.

### Phase 4 - SessionPoller `init/1` Blocking
- SessionPoller does a synchronous tmux call in `init/1`. If tmux hangs (e.g., unresponsive socket), this blocks the entire supervision tree startup. Consider a timeout or async first poll with an empty initial state.

### Phase 8 - YAML Write Failure
- Config GenServer does atomic write (tmp + rename), but doesn't handle disk-full or permission-denied scenarios. Should fall back to in-memory state and alert.

### Phase 14 - Docker Container tmux Session Persistence
- Docker containers are ephemeral. If the container restarts, all tmux sessions are lost. No guidance on volume mounts for session persistence or documentation that this is expected behavior.

---

## 5. Dependency Issues

### Phase 6 References Phase 11's UserSocket
- Phase 6, step 6.9 configures `UserSocket` with auth token verification. But UserSocket's channel registration happens in Phase 11. Phase 6 should note that UserSocket is created as a stub with auth wiring, and Phase 11 adds channel routes to it.

### Phase 7 Assumes Phase 4 Has Expandable Session Cards
- Phase 7 adds action menus to session cards, but Phase 4 already defines the card template. Phase 7 needs to modify Phase 4's template, which is fine, but it should be explicit that the template changes are additive, not from scratch.

### Phase 9 Depends on Phase 10 (Circular)
- Phase 9.3 mentions "pinch-to-zoom" storing preference in localStorage. Phase 10.7 says "update the pinch handler from Phase 9 to persist font size." These are slightly circular: Phase 9 implements the gesture, Phase 10 retrofits it. Fine in practice, but Phase 9 should use a simple localStorage write that Phase 10 later integrates into the preference system.

### Phase 13 Tests Everything But Comes Last
- Phase 13 (Testing & CI) is placed after all feature phases, but each phase already mentions its own tests. Phase 13 should clarify it's about *consolidation and CI setup*, not first-time test writing.

---

## 6. Missing Phases / Coverage Gaps

### No Monitoring / Observability Phase
- No phase covers Telemetry integration, metrics export, or health monitoring beyond the basic `/health` endpoint. The dependencies include `telemetry_metrics` and `telemetry_poller` but they're never wired up. There should be at least a section on what metrics to emit (PaneStream count, active viewers, tmux command latency, etc.).

### No Input Sanitization Phase
- `send_keys` sends raw bytes to tmux. While there's a size limit (128KB), there's no discussion of whether certain byte sequences could escape the tmux pipe-pane context or cause tmux command injection. The `tmux send-keys` command used internally should be `-l` (literal) to avoid key name interpretation.

### No Upgrade / Migration Path
- No phase discusses how to upgrade a running instance. Since there's no database, schema migrations aren't needed, but what about config file format changes between versions? The YAML config should have a version field.

### No Backup / Session Export
- No way to export terminal scrollback or session state. Not essential but worth noting as a gap.

---

## 7. Technical Concerns

### FIFO Per-Pane Scalability
- Each active PaneStream creates a FIFO file and a `cat` process via Erlang Port. With `max_pane_streams: 100`, that's 100 OS processes and 100 open file descriptors minimum. This is fine for the intended use case but could be a concern at scale.

### Ring Buffer Memory
- Default 2MB per pane, max 100 panes = 200MB of ring buffer memory. The defaults are reasonable but there's no global memory cap across all PaneStreams. A burst of pane subscriptions could spike memory.

### Session Polling (3s Interval)
- Three separate pollers (SessionPoller at 3s, Config at 2s, LayoutPoller at 2s) each shell out to tmux. Under load with many windows, this is multiple tmux commands every 2-3 seconds. The design mitigates this with shared pollers, but it's worth noting.

### No WebSocket Heartbeat / Reconnection Protocol
- The LiveView WebSocket gets Phoenix's built-in heartbeat, but the Channel-based native client (Phase 11) doesn't document a reconnection protocol. What happens when a mobile client loses connectivity briefly? The PaneStream enters grace period, and on reconnect, the client gets history from the ring buffer, which is correct. But this flow should be documented explicitly.

### Base64 Encoding Overhead
- All terminal data between LiveView server and browser is base64-encoded (33% overhead). For the Channel path, binary frames avoid this. The LiveView path could use binary frames too via `push_event` with binary data, but this isn't explored.

### `tmux capture-pane` ANSI Escape Handling
- Phase 3 uses `capture-pane -p -e` (with escape sequences) for initial scrollback. This captures the *current* screen state with ANSI escapes, which is correct. But the ring buffer then receives both the capture-pane snapshot AND the ongoing pipe-pane stream. If the pipe-pane was already running when capture-pane executes, there could be duplicate output. The startup sequence does address ordering (pipe-pane attached *before* capture), so the ring buffer gets: [scrollback] then [new output], which is correct. But there's a race: output between step 6 (attach pipe) and step 8 (capture) could appear in both. The pipe output goes to FIFO → Port → coalesce buffer, while capture goes directly to ring buffer. Since Port reads are async, there's a small window where both could contain the same content.

---

## Summary of Critical Issues

1. **PubSub topic/message naming inconsistency** between TmuxManager and SessionPoller (fragile, risk of silent bugs)
2. **`list_panes -a` with `-t`** is contradictory tmux usage (will produce wrong results)
3. **Phoenix Channel binary frame guidance** is inaccurate (needs rewrite for correctness)
4. **LayoutPoller DynamicSupervisor** missing from Phase 1 supervision tree
5. **Credential file permissions** not specified (security gap)
6. **Port exit code 0 doesn't reliably indicate pane death** (FIFO EOF vs actual pane exit)
7. **Telemetry never wired up** despite being a dependency
8. **`send_keys` should use `-l` flag** to prevent tmux key name interpretation as command injection vector
