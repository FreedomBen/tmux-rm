# APPLICATION_DESIGN.md Review Findings

## Inconsistencies

### ~~1. Duplicated MVP Scope~~ RESOLVED
Removed duplicate section, renamed "MVP Scope" → "Scope", replaced all "MVP"/"Post-MVP" language with "Future".

### ~~2. TmuxManager "Not a GenServer for MVP"~~ RESOLVED
Removed "for MVP" qualifier — now just "Not a GenServer".

### ~~3. PaneStream subscribe/unsubscribe arity unclear~~ RESOLVED
Clarified that both `subscribe/1` and `unsubscribe/1` use `self()` to identify the caller.

### ~~4. `get_or_start/1` ownership unspecified~~ RESOLVED
Moved the get-or-start logic into the `subscribe/1` description directly — it now explicitly states it checks Registry and starts under DynamicSupervisor if needed.

## Ambiguities

### ~~5. Scrollback vs ring buffer overlap for late joiners~~ RESOLVED
Unified into a single ring buffer. Scrollback is written into the ring buffer at startup; all viewers receive `{:ok, history}` from the same buffer. Buffer sized dynamically from tmux `history-limit` × pane width (clamped 256KB–4MB, default 1MB fallback). Renamed all events from `"scrollback"` to `"history"`.

### ~~6. Input encoding path underspecified~~ RESOLVED
Specified full encoding pipeline: client uses `TextEncoder` (JS string → UTF-8 bytes) then base64, server decodes base64 then converts to hex for `send-keys -H`. Symmetric with the output path.

### ~~7. `send-keys -H` and multi-byte characters~~ RESOLVED
Covered by #6 fix — `TextEncoder` handles the JS string → UTF-8 conversion client-side.

### ~~8. PubSub topic contains multiple colons~~ RESOLVED
Added inline note clarifying the multiple colons are intentional.

## Insufficiencies

### ~~9. No error handling for `tmux send-keys` failures~~ RESOLVED
`send_keys/2` returns `{:error, :pane_dead}` if status is already `:dead`; logs warning and returns `:ok` on command failure (pane death notification follows via Port EOF).

### ~~10. No FIFO cleanup on application crash~~ RESOLVED
Added application startup cleanup step: `File.rm_rf` then `File.mkdir_p` on the FIFO directory at boot.

### ~~11. Port `cat` non-zero exit unhandled~~ RESOLVED
All exit statuses handled uniformly (set `:dead`, broadcast, clean up). Log level differs: `info` for status 0, `warning` for non-zero.

### ~~12. Grace period race condition~~ RESOLVED
`handle_info(:grace_period_expired)` re-checks `MapSet.size(viewers) == 0` before shutting down. GenServer serialization ensures this check is atomic with respect to subscribe/unsubscribe calls.

### ~~13. No minimum tmux version stated~~ RESOLVED
Added minimum tmux version 2.6+ requirement. `CommandRunner` checks version on first use via `tmux -V`.

### ~~14. CommandRunner `run/1` argument format unspecified~~ RESOLVED
`run/1` takes a list of argument strings, prepends the tmux binary path, executes via `System.cmd/3`.

### 15. `capture-pane -S` flag inconsistency
Line 138 uses `-S -{max_lines}` (e.g., `-S -10000`) but line 529 says `-S -` (all history). These are different behaviors. Pick one and be consistent — `-S -{max_lines}` is correct per the configuration section.

## Minor Issues

### 16. xterm.js core package name
Line 363 says "xterm.js 5.x" but since v5 the npm package is `@xterm/xterm` (scoped). The addon references already use `@xterm/addon-fit` — the core package name should match.

### 17. `pipe-pane -o` rationale missing
Line 136 uses `-o` (output only) without explaining why. Worth a brief note: without `-o`, input echo would also be captured, causing doubled input for viewers when the pane has echo enabled.
