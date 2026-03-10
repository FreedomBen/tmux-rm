# Design Review: Open Questions

Issues found during review of APPLICATION_DESIGN.md that need decisions.

## Q1 — WebSocket rate limiting mechanism

The rate limit for `/socket/websocket` is described as a Plug, but WebSocket upgrades have a special path through Phoenix/cowboy. Options:

- **(a)** Check in `UserSocket.connect/3` (has access to `connect_info` including peer IP) — simple, but mixes auth and rate-limit concerns
- **(b)** Plug in the Endpoint pipeline that matches the `/socket/websocket` path before the upgrade
- **(c)** A custom `check_origin`-style callback

## Q4 — Session cookie TTL

How should the 30-day cookie TTL be implemented?

- **(a)** `Plug.Session` `max_age` option — browser discards the cookie after 30 days. Simple but the server can't distinguish "expired" from "never had one"
- **(b)** Embed a timestamp in the signed session data, validate on each request in `AuthHook` — server-side control, can show "session expired, please log in again" vs "not logged in"
- **(c)** Both (belt and suspenders)
