# APPLICATION_DESIGN.md — Review Findings

## Fixed

1. **TmuxManager diagram label**: The High-Level Components diagram labeled TmuxManager as "(GenServer)" but the module description (line 89) and supervision tree (line 556) both confirm it's a stateless module. Fixed the diagram to say "(stateless module)".

2. **Config GenServer missing from diagram**: The `Config` GenServer appeared in the Supervision Tree section but was absent from the High-Level Components ASCII diagram. Added it.

## Open Questions

### ~~1. PubSub Topic Naming Inconsistency~~ — Resolved

Clarified in the Channel section that the Channel join topic (`"terminal:..."`) is a client-facing concern, not a PubSub topic. The join handler converts it to the canonical target and subscribes to the same `"pane:#{target}"` PubSub topic that LiveView uses. No format unification needed.

### ~~2. Session/Window Rename Fragility~~ — Resolved

Added dual Registry key (`{:pane_id, pane_id}`) and a supersede mechanism. During startup, the new PaneStream detects collisions with stale PaneStreams via the secondary key, sends `:superseded`, and takes over. The old PaneStream cleans up and notifies its viewers. Updated in: Registration, startup sequence step 0b, Lifecycle, Session/Window Renamed Externally section, and Resolved Design Decisions #12.

### ~~3. No Consolidated Event Table~~ — Resolved

Added an "Event Reference" subsection under Data Flow with five tables: LiveView events (TerminalLive), LiveView events (SettingsLive), PubSub messages (pane topic), PubSub messages (other topics), and Phoenix Channel events (future). All events, directions, payloads, and descriptions in one place.

### ~~4. Channel Protocol Underspecified~~ — Resolved

Fully specified the Channel protocol in both the Architecture section (TerminalChannel) and Feature Designs (Channel Protocol). Added: join reply payload with cols/rows, error replies, `reconnected` and `pane_superseded` events, input validation (128KB limit, resize bounds), leave/disconnect/reconnect behavior, and auth flow reference. Updated the Event Reference table to match.

### ~~5. Bandwidth Optimization Gap~~ — Resolved

Expanded the Bandwidth Optimization section from a brief list to 7 detailed strategies with implementation specifics: (1) streaming not polling, (2) WebSocket `permessage-deflate` with Phoenix config, (3) server-side output coalescing with configurable 3ms window + 32KB flush threshold + IO list accumulator, (4) binary Channel frames for native app, (5) client-side input batching via `requestAnimationFrame`, (6) debounced resize, (7) ring buffer cap. Each strategy includes rationale for why it's safe on fast connections. Added `output_coalesce_ms` and `output_coalesce_max_bytes` to the Configuration section. Strategies that would hurt fast connections (aggressive throttling, delta encoding) are explicitly noted as avoided.

### ~~6. Mixed Requirement Language~~ — No Action Needed

On closer inspection, the language is used consistently: "must" = mandatory constraints (validation, security, startup ordering), "should" = recommended client behavior / implementation guidance, "will" = describes designed system behavior. No normalization needed.
