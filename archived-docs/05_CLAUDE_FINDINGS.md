# APPLICATION_DESIGN.md Review — Open Questions

Issues found during review that require a design decision before implementation.

## ~~1. Scrollback Deduplication: Suffix Match Will Rarely Succeed~~ — RESOLVED

**Decision: Option B** — Accept overlap, no deduplication. The format mismatch between `capture-pane` (rendered screen dump) and `pipe-pane` (raw terminal protocol) is fundamental — not just ANSI differences but structural (newline-delimited padded lines vs cursor-addressed raw bytes). Byte-level deduplication would require server-side terminal emulation. Overlap is bounded by the millisecond window between pipe-pane attach and capture-pane, not by scrollback size. Updated in `APPLICATION_DESIGN.md`.

## ~~2. `send_keys` Failure on Session Rename: Silent Input Loss~~ — RESOLVED

**Decision: Option B** — Use tmux's stable `pane_id` (e.g., `%0`) for all tmux commands. Resolved during startup step 0 via `tmux display-message -p -t {target} '#{pane_id}'`. Human-readable `target` kept for Registry, PubSub, display, and URLs. Renames no longer affect input or output. Minor edge case documented: a rename can briefly result in two PaneStreams for the same underlying pane (old target + new target), resolved by grace period. Updated in `APPLICATION_DESIGN.md`.

## ~~3. Quick Actions Config Persistence: No Concurrency Model~~ — RESOLVED

**Decision: Option A** — `Config` is now a GenServer that serializes all reads/writes, holds parsed config in memory, polls the file's mtime every 2s to detect external edits, and broadcasts `{:config_changed, config}` on PubSub topic `"config"`. LiveViews (`TerminalLive`, `SettingsLive`) subscribe on mount and update assigns on change. `QuickActionController` calls the same GenServer API. Malformed file on reload keeps last-good config in memory. Added to supervision tree (after PubSub, before Endpoint). Updated in `APPLICATION_DESIGN.md`.

## ~~4. Ring Buffer Aggregate Memory~~ — RESOLVED

**Decision: Generous defaults + simple memory pressure check.** Raised limits: `ring_buffer_min_size` 256KB → 512KB, `ring_buffer_max_size` 4MB → 8MB, `ring_buffer_default_size` 1MB → 2MB. Worst case: 100 × 8MB = 800MB, acceptable for target machines. For low memory defense: each PaneStream checks `:erlang.memory(:total)` against `memory_high_watermark` (default 768MB) at startup. If exceeded, new panes use `ring_buffer_min_size` and log a warning. Existing streams are untouched. No central coordinator needed — `max_pane_streams` is the hard bound, memory check is the soft degradation. Updated in `APPLICATION_DESIGN.md`.
