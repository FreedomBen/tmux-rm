# APPLICATION_DESIGN.md Review — Open Questions

Issues found during review that require a design decision before implementation.

## ~~1. Scrollback Deduplication: Suffix Match Will Rarely Succeed~~ — RESOLVED

**Decision: Option B** — Accept overlap, no deduplication. The format mismatch between `capture-pane` (rendered screen dump) and `pipe-pane` (raw terminal protocol) is fundamental — not just ANSI differences but structural (newline-delimited padded lines vs cursor-addressed raw bytes). Byte-level deduplication would require server-side terminal emulation. Overlap is bounded by the millisecond window between pipe-pane attach and capture-pane, not by scrollback size. Updated in `APPLICATION_DESIGN.md`.

## ~~2. `send_keys` Failure on Session Rename: Silent Input Loss~~ — RESOLVED

**Decision: Option B** — Use tmux's stable `pane_id` (e.g., `%0`) for all tmux commands. Resolved during startup step 0 via `tmux display-message -p -t {target} '#{pane_id}'`. Human-readable `target` kept for Registry, PubSub, display, and URLs. Renames no longer affect input or output. Minor edge case documented: a rename can briefly result in two PaneStreams for the same underlying pane (old target + new target), resolved by grace period. Updated in `APPLICATION_DESIGN.md`.

## ~~3. Quick Actions Config Persistence: No Concurrency Model~~ — RESOLVED

**Decision: Option A** — `Config` is now a GenServer that serializes all reads/writes, holds parsed config in memory, polls the file's mtime every 2s to detect external edits, and broadcasts `{:config_changed, config}` on PubSub topic `"config"`. LiveViews (`TerminalLive`, `SettingsLive`) subscribe on mount and update assigns on change. `QuickActionController` calls the same GenServer API. Malformed file on reload keeps last-good config in memory. Added to supervision tree (after PubSub, before Endpoint). Updated in `APPLICATION_DESIGN.md`.

## 4. Ring Buffer Aggregate Memory

10 panes at 4MB each = 40MB just for ring buffers. The `max_pane_streams: 100` cap bounds worst case to 400MB. No global memory budget exists.

**Options:**
- **A)** Add a global memory budget (e.g., `ring_buffer_total_max: 32_MB`) and reduce per-pane sizes when approaching the limit
- **B)** Keep per-pane limits as-is. Document the worst-case math (100 × 4MB = 400MB) and accept it for a server-class machine.
- **C)** Lower the default `ring_buffer_max_size` ceiling (e.g., 1MB instead of 4MB)
