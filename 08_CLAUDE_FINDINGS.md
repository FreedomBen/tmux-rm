# APPLICATION_DESIGN.md Review — Open Questions

## ~~Q1: Binary transport on Phoenix Channel~~ — RESOLVED

**Decision**: Option (a) — V2 binary serializer. Text frames (JSON) for control messages, binary frames (V2 header format) for terminal data. Updated: Bandwidth Optimization section, Channel Protocol, Kotlin client classes, TerminalSession code.

## ~~Q2: Unstable IDs when YAML is hand-edited without `id` fields~~ — RESOLVED

**Decision**: Option (a) — write IDs back to the file after first load. Updated: `parse/1` returns `ids_generated?` flag, `init/1` and `handle_info(:poll_config)` write back when IDs were generated, schema description and loading docs updated.

## ~~Q3: Retrofit or plain OkHttp for Android REST calls?~~ — RESOLVED

**Decision**: Option (a) — added Retrofit to the tech stack table alongside OkHttp + kotlinx.serialization.

## ~~Q4: Auth session TTL `0 = never expire`~~ — RESOLVED

**Decision**: Accept both `0` and `nil` as "never expire". Updated doc to say `0` or `nil`.

## ~~Q5: Android session list — polling vs Channel push?~~ — RESOLVED

**Decision**: Option (b) — `SessionChannel` for real-time push. Added `session_channel.ex` to server project structure. Android joins `"sessions"` topic for live updates, REST API retained for mutations and pull-to-refresh fallback. Removed 5-second HTTP polling.

## Q6: Foreground service lifecycle precision

Line 2105 says the service "is stopped when the user navigates away from all terminal sessions." What exactly triggers this?

Options:
- **(a)** Service stops when the last `PhoenixChannel` topic is left (i.e., user leaves the last Terminal Screen)
- **(b)** Service stops when the app's Activity is destroyed (process death / explicit close)
- **(c)** Service persists as long as the WebSocket is connected, stops on explicit disconnect or token expiry
