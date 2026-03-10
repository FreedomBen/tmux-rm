# APPLICATION_DESIGN.md Review Findings

## Fixes Applied

1. **Memory spike bound formula**: Fixed from `max_pane_streams × ring_buffer_max_size` to `concurrent_viewers × ring_buffer_max_size`, with note that serialization through the GenServer means only one copy exists at a time in practice.
2. **Resize inconsistency between LiveView and Channel**: Added clarifying note to both Channel event tables (Data Flow and Feature Designs) that Channel resize calls `tmux resize-pane`, unlike Phase 1 LiveView which stores only.
3. **PubSub ordering safety**: Added note explaining why subscribing to PubSub before the PaneStream exists is safe (no publisher yet).
4. **Android table row formatting**: Moved the Android row back inside the Technology Choices table (was orphaned after the TERM paragraph).
5. **Quick Actions `confirm` behavior**: Expanded the schema description to specify LiveView modal (not `window.confirm()`), with command text display and mobile-friendly buttons.
6. **Scope vs Prioritization link**: Added introductory sentence to Implementation Prioritization clarifying it covers post-Phase-1 features.

## Open Questions

### ~~1. Auth token storage — two locations~~ RESOLVED

Replaced token-based auth with username+password authentication. Credentials (username + bcrypt hash) stored in `~/.config/remote_code_agents/credentials`. `RCA_AUTH_TOKEN` env var retained as fallback for headless/automated setups. `mix rca.setup` handles initial credential creation; `mix rca.change_password` for updates. Added `bcrypt_elixir` dependency. Updated: auth section, storage table, runtime.exs snippet, technology choices table.

### ~~2. Grace period duration~~ RESOLVED

Changed default from 5s to 30s. Updated in both the PaneStream lifecycle description and config.exs (`pane_stream_grace_period: 30_000`).

### ~~3. `max_pane_streams` — where configured, what default?~~ RESOLVED

Already fully specified in the doc: DynamicSupervisor `max_children: 100`, configurable via `config :remote_code_agents, max_pane_streams: 100`. `subscribe/1` returns `{:error, :max_pane_streams}` when the limit is hit. No changes needed.

### ~~4. CSRF protection for REST API~~ RESOLVED

REST API (`/api/*`) routes are exempt from CSRF — they use bearer token auth via `Authorization` header, which isn't vulnerable to CSRF (not auto-attached by the browser). LiveView forms keep Phoenix's built-in CSRF protection (default behavior). Added to Security Considerations section.

### ~~5. Rate limiting on `send_keys`~~ RESOLVED

No rate limiting needed. Single-user personal tool — the only sender is the authenticated user. The 128KB payload cap prevents accidental oversized payloads. Rate limiting would risk throttling legitimate fast input (key repeat, paste). No doc changes.

### ~~6. tmux socket path~~ RESOLVED

Added `tmux_socket` config option. `CommandRunner` prepends `-S <path>` or `-L <name>` to all tmux commands when set. Added to CommandRunner description and config block.

### 7. Testing strategy

The section is quite thin for a doc this detailed. Should it be expanded with specific approaches (mock `CommandRunner` for unit tests, real tmux for integration tests, LiveView test helpers, etc.), or left lean?

### 8. Logging strategy

Should a section on structured logging / log format be added, or is the current inline approach (log levels mentioned per-event) sufficient?

### ~~9. HTTPS for remote access~~ RESOLVED

The HTTPS section already existed in the doc (under Feature Designs > Authentication & Remote Access > HTTPS) with three options (reverse proxy, Phoenix direct TLS, Tailscale/WireGuard) and a recommendation for Tailscale. The clipboard section just needed to reference it — no additional content needed.
