# APPLICATION_DESIGN.md Review — Open Questions

## ~~#5/#6 — SessionChannel Design~~ RESOLVED

Resolved: Option (c) — each `SessionChannel` subscribes to PubSub `"sessions"` for instant updates + runs its own poll timer for external changes. Dedicated `SessionChannel` design section added to APPLICATION_DESIGN.md (after TerminalChannel), plus SessionChannel events added to the Event Reference table.

## ~~#11 — Rate Limiting~~ RESOLVED

Resolved: Per-IP rate limiting added to Security Considerations section. Three endpoints rate limited: `POST /api/login` (5/min), WebSocket upgrade (10/min), `POST /api/sessions` (10/min). Implementation via `RateLimit` Plug using ETS. Configurable limits, lazy cleanup, only active in remote mode. Added `rate_limit.ex` to project structure, rate limit pipeline to routes.

## ~~#12 — Certificate Pinning for Android~~ RESOLVED

Resolved: Option (b) — standard TLS only, no pinning or TOFU. TOFU is complex (cert rotation false alarms), pinning is brittle, and the recommended deployment is Tailscale/VPN anyway. Added TLS rationale section under Android Token Management.

## ~~#17 — Retrofit vs Ktor~~ RESOLVED

Resolved: Switched to Ktor Client + kotlinx.serialization. Pure Kotlin, first-class serialization support, coroutine-native. Uses `ktor-client-okhttp` engine to share the OkHttp instance with the WebSocket layer. Updated tech stack table, architecture diagram, project structure (`ApiService.kt` → `ApiClient.kt`, `AuthInterceptor.kt` → `AuthPlugin.kt`), and DI module description.

## ~~#7/#8 — Android Quick Action Validation & Termux Dependency~~ RESOLVED

Resolved:

1. **Quick action validation**: No client-side validation needed. Quick action commands are user-configured strings (typically a few hundred bytes). The server enforces the 128KB limit on all Channel `"input"` events, covering all input paths. Documented in Android Terminal Screen lifecycle.

2. **Termux dependency**: Local Gradle module at `android/terminal-lib/` instead of a separate published package. App depends via `implementation(project(":terminal-lib"))`. Updated Resolved Decisions section and project structure.
