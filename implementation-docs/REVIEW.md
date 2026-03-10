# Implementation Phase Documents - Review

## Overall Assessment

The 15 phases are thorough, well-structured, and show clear architectural thinking. The FIFO/pipe-pane streaming design, the CommandRunner abstraction for testability, and the graceful PaneStream lifecycle are all well-considered.

---

## Resolved Issues

The following issues were identified and fixed in the phase documents:

### 1. PubSub Topic Separation ✅
**Was**: TmuxManager and SessionPoller both broadcast on `"sessions"` with different message shapes.
**Fixed**: TmuxManager uses `"sessions:mutations"` (trigger events, no payload). SessionPoller uses `"sessions:state"` (full session list snapshots). All consumers updated across Phases 2, 4, 11, 12.

### 2. `list_panes -a` with `-t` ✅
**Was**: `-a` (all sessions) conflicts with `-t` (target session).
**Fixed**: Phase 2 uses `-s` (all panes in session across windows) — was already corrected in phase doc.

### 3. tmux Minimum Version ✅
**Was**: Required tmux 2.6+, but `send-keys -H` (hex input) requires tmux 3.1+.
**Fixed**: Phase 1 now requires tmux 3.1+. All version checks updated.

### 4. Phoenix Channel Binary Frame API ✅
**Was**: `push(socket, "output", {:binary, data})` — invalid Phoenix API.
**Fixed**: Phase 11 now documents `{:push, {:binary, data}, socket}` return from `handle_info/2` for raw binary frames, with base64 fallback guidance.

### 5. TerminalChannel Ownership ✅
**Was**: Unclear whether Phase 5 or Phase 11 builds TerminalChannel.
**Fixed**: Phase 5 builds the core TerminalChannel (join, output, input, PaneStream subscription). Phase 11 extends it and adds SessionChannel.

### 6. UserSocket Creation Ownership ✅
**Was**: Three phases (5, 6, 11) touch UserSocket with unclear creation order.
**Fixed**: Phase 5 creates UserSocket stub (pass-through connect). Phase 6 adds token auth to connect. Phase 11 adds SessionChannel registration.

### 7. Credential File Permissions ✅
**Was**: No permissions specified for credentials file.
**Fixed**: Phase 6 already specifies `0o600` via `File.chmod/2` — was already in the doc.

### 8. `send_keys` Uses `-l` Flag ✅
**Was**: No `-l` flag risked tmux key name interpretation.
**Fixed**: Phase 3 already uses `-l -H` — was already in the doc.

### 9. Telemetry Wiring Gap ✅
**Was**: Telemetry deps in Phase 1, not wired until Phase 15.
**Fixed**: Phase 1 now starts `RemoteCodeAgents.Telemetry` supervisor in supervision tree. Phase 15 adds implementation note to instrument incrementally per phase.

### 10. LayoutPollerSupervisor in Phase 1 ✅
**Was**: Noted as missing from supervision tree.
**Fixed**: Phase 1 step 1.6 already includes it — review was outdated.

### 11. Phase 13 Role Clarification ✅
**Was**: Unclear whether Phase 13 is first-time test writing or CI setup.
**Fixed**: Phase 13 goal now explicitly states tests are written per-phase; this phase is CI/CD setup and coverage consolidation.

### 12. Phase 9/10 Circular Dependency ✅
**Was**: Phase 9 pinch-to-zoom stores in localStorage, Phase 10 retrofits it.
**Fixed**: Phase 9 now defines a minimal `savePref`/`loadPref` interface using the same `rca-preferences` localStorage key. Phase 10 replaces the helpers with the full system — no retrofit needed.

### 13. Reverse Proxy/TLS Guidance ✅
**Was**: Phase 14 mentioned options without examples.
**Fixed**: Phase 14 now includes Caddy and nginx config examples with WebSocket support.

---

## Remaining Open Questions

These require design decisions before implementation:

### A. Port Exit vs Pane Death Ambiguity
`cat` on a FIFO returns exit 0 on any EOF (pipe-pane detach, tmux reload, actual pane death). Phase 3 already handles this with a `tmux display-message` existence check after every port exit, but there's a race window. **Mitigation is documented and acceptable** — the existence check covers the common cases.

### B. FIFO-per-Pane Scalability
100 panes = 100 `cat` processes + file descriptors. Phase 1's `max_pane_streams` config caps this. No cleanup on SIGKILL (terminate/2 won't fire). **Acceptable for intended use case** — document the limitation.

### C. tmux Server Restart Recovery
If tmux restarts, all FIFOs are orphaned, pane IDs invalidated, pipe-pane attachments gone. Each PaneStream detects this independently (port exit → existence check fails → `:dead`). **No coordinated recovery** — acceptable since tmux restart is rare and destructive by nature.

### D. bcrypt → pbkdf2 ✅
Switched from `bcrypt_elixir` (NIF, requires C compiler) to `Plug.Crypto.hash_pwd_salt` (PBKDF2, pure Elixir). Removed `bcrypt_elixir` from deps, removed `build-essential` from Dockerfile. Sufficient for single-user system.

### E. URL Scheme — Keep `/terminal/:target` ✅
Colons in the target (e.g., `mysession:0.1`) are URL-safe enough — Phoenix captures the full path segment. Kept as-is.

### F. Binary Frame Approach ✅
Plan to verify `{:push, {:binary, data}, socket}` during Phase 5 implementation, with base64 fallback ready. Already documented in Phase 11.

### G. Multiple xterm.js Performance
Multi-pane view (Phase 12) creates one xterm.js per pane. No max pane count guidance. **Consider**: documenting a recommended max (8-12 panes) and degrading gracefully beyond that.
