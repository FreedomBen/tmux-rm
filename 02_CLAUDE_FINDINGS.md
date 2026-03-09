# APPLICATION_DESIGN.md — Pre-Implementation Review Findings

## Errors & Inconsistencies

### 1. `YamlElixir.Encoder.encode/1` doesn't exist
**Location**: Line 1180
`yaml_elixir` is a parser only — it has no encoder module. Need a separate library like `ymlr` for YAML writing, or build the YAML string manually (the structure is simple enough).

### 2. `send_keys/2` type mismatch
**Location**: Line 1027 vs line 301
Quick action code passes a charlist (`bytes = :binary.bin_to_list(command_with_enter)`) to `PaneStream.send_keys/2`, but the main design says `send_keys` receives raw bytes (binary) from `Base.decode64!/1`. The interface should be consistent — binary everywhere, since Elixir is binary-native.

### 3. Ring buffer "single contiguous binary" claim
**Location**: Line 102
`subscribe/1` returns history as "a single contiguous binary", but a ring buffer by nature has a wrap point. `RingBuffer.read/1` must concatenate the two halves. Not wrong, but the implementation needs to account for this.

### 4. `pipe-pane` `-o` flag description
**Location**: Line 137
`-o` is described as "output only (not input echo)". Actually, `-o` means output only (stdout of the pane's process). Without `-o`, `pipe-pane` captures both directions. The parenthetical is slightly misleading — it's not about echo, it's about capturing only the output side of the pty.

## Missing Details

### 5. No ring buffer module specified
The design references a ring buffer extensively but never specifies its module name or API. Need to define `RemoteCodeAgents.RingBuffer` with `new/1`, `append/2`, `read/1`, `size/1` and add it to the project structure.

### 6. PaneStream `get_or_start` not defined
**Location**: Line 587 vs lines 101–104
Line 587 mentions `get_or_start/1` as the pattern, but the Interface section only lists `subscribe/1` as doing the "check Registry, start if not found" logic. Clarify whether `get_or_start` is a separate public function or internal logic within `subscribe/1`.

### 7. FIFO directory cleanup on boot — no implementation location
**Location**: Line 167 vs lines 468–481
The design says "On application boot, the FIFO directory is cleared" but this isn't reflected in `application.ex` or the supervision tree. Need to specify where this runs — recommend `Application.start/2` before the supervisor tree starts.

### 8. PubSub topic subscription timing — potential race
**Location**: Line 247 vs line 277
TerminalLive subscribes to PubSub topic `"pane:#{target}"` and separately calls `PaneStream.subscribe/1` which returns history. If the PubSub subscription happens after `subscribe/1` returns, messages broadcast between those two calls are lost. Recommend `PaneStream.subscribe/1` handles PubSub subscription internally, or clarify the ordering guarantee.

### 9. `handle_params` vs `mount` — contradictory
**Location**: Line 244 vs line 962
Line 244 says TerminalLive uses `handle_params/3` for pane subscription, but line 962 shows `mount/3` loading config and doing setup. Need to reconcile — for a non-live-navigated page, `mount` is simpler.

### 10. No error handling for base64 decode
**Location**: Line 250
`Base.decode64!/1` raises on invalid input. A malicious or buggy client could crash the LiveView. Should use `Base.decode64/1` with pattern matching and error handling.

### 11. Grace period timer — no timer ref in state
**Location**: Line 107 vs lines 94–99
The design mentions `Process.cancel_timer/1` for the grace period but the PaneStream State section doesn't include a `grace_timer_ref` field. Add it to the state definition.

## Ambiguities

### 12. ~~What happens when PaneStream starts but the tmux pane doesn't exist?~~ RESOLVED
Fixed: `subscribe/1` returns `{:error, :pane_not_found}` and `mount/3` shows error UI.

### 13. ~~URL param format for window and pane~~ RESOLVED
Fixed: `mount/3` documents target construction as `"#{session}:#{window}.#{pane}"` with window and pane as integer indices.

### 14. ~~Session list polling vs streaming philosophy~~ RESOLVED
Fixed: Hybrid approach — instant PubSub updates for app-driven changes (`TmuxManager` broadcasts `{:sessions_changed}` on create/kill), 3s polling fallback for external changes only.

### 15. `send-keys -H` and multi-byte UTF-8
**Location**: Line 211
Hex bytes are space-separated. Confirm tmux handles multi-byte UTF-8 sequences correctly (e.g., emoji = 4 bytes sent as 4 separate hex values). It does, but worth an explicit test case.

## Minor Nits

- **Line 406**: `yaml_elixir 2.9+` — current version is `2.11`, pin to `~> 2.11`
- **Line 394**: `Elixir 1.16+` — consider `1.17+` since that's current
- **Line 1278**: Settings page route is outside any scope/pipeline — needs to be inside the authenticated pipeline

## Recommendations Before Implementation

1. **Fix the YAML encoder** — switch to `ymlr` or manual string building
2. **Add `RingBuffer` module** to project structure with defined API
3. **Add `grace_timer_ref`** to PaneStream state definition
4. **Clarify the subscribe/PubSub race** — recommend `PaneStream.subscribe/1` both adds the viewer AND subscribes them to PubSub, returning history, guaranteeing no gap
5. **Define error paths** for invalid pane targets at subscription time
6. **Standardize `send_keys/2` input type** as binary
