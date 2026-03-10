# APPLICATION_DESIGN.md Review — Open Questions

## ~~Q1: Binary transport on Phoenix Channel~~ — RESOLVED

**Decision**: Option (a) — V2 binary serializer. Text frames (JSON) for control messages, binary frames (V2 header format) for terminal data. Updated: Bandwidth Optimization section, Channel Protocol, Kotlin client classes, TerminalSession code.

## ~~Q2: Unstable IDs when YAML is hand-edited without `id` fields~~ — RESOLVED

**Decision**: Option (a) — write IDs back to the file after first load. Updated: `parse/1` returns `ids_generated?` flag, `init/1` and `handle_info(:poll_config)` write back when IDs were generated, schema description and loading docs updated.

## ~~Q3: Retrofit or plain OkHttp for Android REST calls?~~ — RESOLVED

**Decision**: Option (a) — added Retrofit to the tech stack table alongside OkHttp + kotlinx.serialization.

## Q4: Auth session TTL `0 = never expire`

Using 0 to mean "infinite" is unconventional.

Options:
- **(a)** Leave it as-is (it's documented, just unusual)
- **(b)** Change to `nil` = never expire, `0` is not a valid value
- **(c)** Change to a negative value like `-1` = never expire

## Q5: Android session list — polling vs Channel push?

The Android app polls `GET /api/sessions` every 5 seconds. Since the WebSocket is already open, a `SessionChannel` topic could push session list changes in real-time (lower overhead, consistent with web UI's PubSub approach).

Options:
- **(a)** Keep HTTP polling (simpler, good enough for the use case)
- **(b)** Switch to a `SessionChannel` topic for real-time push (lower overhead, consistent with web PubSub)

## Q6: Foreground service lifecycle precision

Line 2105 says the service "is stopped when the user navigates away from all terminal sessions." What exactly triggers this?

Options:
- **(a)** Service stops when the last `PhoenixChannel` topic is left (i.e., user leaves the last Terminal Screen)
- **(b)** Service stops when the app's Activity is destroyed (process death / explicit close)
- **(c)** Service persists as long as the WebSocket is connected, stops on explicit disconnect or token expiry
