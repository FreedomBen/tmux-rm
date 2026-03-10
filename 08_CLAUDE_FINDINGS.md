# APPLICATION_DESIGN.md Review — Open Questions

## Q1: Binary transport on Phoenix Channel

The doc claims raw binary payloads on the Channel (no base64), but the protocol is described as JSON-framed `[join_ref, ref, topic, event, payload]`. These are contradictory — you can't put raw bytes in JSON.

Options:
- **(a)** Use Phoenix's V2 binary serializer (a real thing — it uses a binary envelope format instead of JSON). Document this as the serializer choice for the Channel socket.
- **(b)** Accept base64 encoding on the Channel too, and remove the "no base64, 33% savings" claims. The Channel still benefits from WebSocket compression (`permessage-deflate`).

## Q2: Unstable IDs when YAML is hand-edited without `id` fields

`normalize_action` generates a random ID when `id` is missing. If a user hand-edits the YAML and doesn't include IDs, every reload generates new ones — breaking any client that cached them (Android app).

Options:
- **(a)** Write IDs back to the file after first load (mutates the user's file, but stabilizes IDs permanently)
- **(b)** Use a deterministic fallback ID (e.g., hash of `label + command`) so the same action always gets the same ID even without an explicit one
- **(c)** Both — deterministic fallback for immediate stability, plus write IDs back on first load for explicitness

## Q3: Retrofit or plain OkHttp for Android REST calls?

Line 2159 references `Retrofit/OkHttp` but the tech stack table only lists `OkHttp + kotlinx.serialization`.

Options:
- **(a)** Add Retrofit to the tech stack (it's a natural fit with OkHttp for REST APIs)
- **(b)** Remove the Retrofit reference and keep it as plain OkHttp + manual request building

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
