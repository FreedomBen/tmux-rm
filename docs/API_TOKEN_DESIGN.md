# API Token UI — design doc

## Background

termigate has two ways to authenticate today:

1. **Username + password** — bcrypt-style PBKDF2-HMAC-SHA256 hash stored under
   `auth.password_hash` in `config.yaml`. Used by the web LiveView login.
2. **Static token via `TERMIGATE_AUTH_TOKEN` env var** — when set, this string
   is accepted as the *password* at both `/login` (web) and `/api/login`
   (JSON). On success, the server mints a `Phoenix.Token`-signed bearer
   token (`"api_token"` salt) that the API client uses in
   `Authorization: Bearer …` for the rest of its session.

Two consequences of the current design that this doc tries to fix:

- The `TERMIGATE_AUTH_TOKEN` env var is the only knob for non-interactive
  clients (Android app, MCP, CI, scripts). To rotate it, the operator has
  to restart the container with a new env value. There is no in-app way
  to view it, rotate it, or generate scoped tokens.
- The bearer tokens minted at `/api/login` carry the auth session TTL
  (`auth.session_ttl_hours`, default 168h). They expire silently and
  cannot be revoked early. There is also no way to look at "what tokens
  are currently valid" or "when was each one last used".

The 2026-04-30 server-drive flagged this as a minor gap on `/settings`:
operators have no UI to manage tokens.

## Goals

- Operators can **mint long-lived API tokens** from `/settings` with a
  human label ("Android — Pixel 8", "MCP — Claude Code on laptop", "CI
  — staging deploy").
- Operators can **revoke any token** without restarting the container.
- The system records **when each token was last used**, so stale tokens
  are easy to clean up.
- The Android app, MCP server, and any third-party API client work with
  these UI-minted tokens *exactly the same way* they work with a
  bearer minted from `/api/login` today (`Authorization: Bearer …`).
- The `TERMIGATE_AUTH_TOKEN` env var keeps working unchanged so existing
  deployments are not broken.

## Non-goals

- Per-token permission scopes / ACLs. v1 tokens are full-access, just
  like the current single env-var token. (Add later if a real use case
  appears — e.g., read-only tokens for monitoring.)
- A separate "user" concept. termigate is single-user; tokens belong to
  the configured admin.
- Sharing tokens between termigate instances. Each instance manages its
  own.
- Showing the plaintext token after creation. Tokens are stored hashed
  and only the **once-on-create** modal sees plaintext.

## Threat model

Tokens grant **full API access** to the termigate server, which in turn
controls a tmux multiplexer and can run arbitrary shell commands. A
leaked token is functionally equivalent to a leaked password.

Mitigations:

- Tokens are stored hashed (PBKDF2-HMAC-SHA256, same primitive as
  `auth.password_hash`) so a `config.yaml` leak does not leak tokens.
- Plaintext is shown exactly once, in a modal, with a "copy" button and
  a "I've copied it" confirmation that closes the modal and zeroes the
  in-memory copy.
- Server logs the token *id* (a short opaque prefix), never the
  plaintext. Existing `Logger.info("Login success: …")` lines do not
  include token contents and we will not add any that do.
- Each token has a `last_used_at` timestamp updated on verification,
  written back to `config.yaml` asynchronously (debounced) so a leaked
  token is detectable.

## Data model

A new section in `config.yaml`:

```yaml
api_tokens:
  - id: "tk_8f2a"            # short random prefix shown in UI/logs
    label: "Android — Pixel 8"
    hash: "<base64 salt>$<base64 dk>"  # same format as password_hash
    created_at: 1714492800   # unix seconds
    last_used_at: 1714579200 # unix seconds, or nil if never used
```

Choices and rationale:

- **List, not map.** Order is preserved (newest first when rendered),
  and JSON/YAML round-tripping is simpler.
- **`id` is a short random prefix**, not a UUID. Long enough to be
  unique in a single deployment (4–6 hex chars) and short enough to be
  a useful log/UI identifier. The full token is the prefix plus a
  longer secret half: `tk_8f2a_<32-byte-base64url-secret>`.
- **`hash`** uses the same `salt$dk` PBKDF2 envelope as
  `auth.password_hash` so verification reuses `Auth.verify_password/2`.
- **`last_used_at`** is updated on every successful verification but
  only persisted to disk on a debounce (e.g. flush at most every 30s
  per token) to avoid YAML churn.

## Token format

```
tk_<id>_<secret>
   │     │
   │     └─ 32 bytes random, base64url-encoded → 43 chars
   └─────── 4 hex chars (16 bits)
```

Total length ≈ 50 chars. The `tk_` prefix + id makes leaked tokens
self-identifying in logs and grep, and lets the server look up the
hash by id in O(1) before doing the constant-time hash comparison.

The id is also surfaced in the UI ("Token tk_8f2a — last used 2 hours
ago") so operators can correlate UI state with logs.

## Auth flow changes

`TermigateWeb.Plugs.RequireAuthToken.call/2` currently does:

```elixir
with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
     {:ok, _data} <- Phoenix.Token.verify(..., "api_token", token, max_age: ttl) do
  conn
else
  _ -> 401
end
```

New flow:

```elixir
with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
     :ok <- verify_bearer(token) do
  conn
else
  _ -> 401
end
```

where `verify_bearer/1` tries, in order:

1. **Stored API token** — if `token` starts with `tk_`, parse the id,
   look up the matching record in `config.api_tokens`, and verify with
   `Auth.verify_password(secret, record.hash)`. On success, schedule
   a debounced `last_used_at` update.
2. **Phoenix.Token (legacy)** — fall through to the existing
   `Phoenix.Token.verify(...)` so already-issued login tokens stay
   valid until they expire.
3. **Env var (legacy)** — if `TERMIGATE_AUTH_TOKEN` is set and equals
   `token` byte-for-byte (`Plug.Crypto.secure_compare/2`), accept.
   This preserves existing deployments that hardcode the env-var token
   into a script's `Authorization: Bearer $TERMIGATE_AUTH_TOKEN` header.

Order matters: prefix-matching `tk_` first means the common path is
fast (one lookup + one PBKDF2). Phoenix.Token verification is more
expensive (HMAC + binary_to_term) and env-var compare is the rare
fallback.

## UI

New section on `/settings`, between "TERMINAL APPEARANCE" and the
existing "CHANGE PASSWORD" block.

```
┌─ API TOKENS ──────────────────────────────────────────────┐
│                                                           │
│  Generate tokens for non-interactive clients (the Android │
│  app, MCP, CI). Each token has full API access until      │
│  revoked.                                                 │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │ Label                Created      Last used   Action│  │
│  ├─────────────────────────────────────────────────────┤  │
│  │ Android — Pixel 8    Apr 12       2h ago     Revoke │  │
│  │ MCP — laptop         Apr 03       Just now   Revoke │  │
│  │ CI — staging         Mar 28       Never      Revoke │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  [ + Generate new token ]                                 │
└───────────────────────────────────────────────────────────┘
```

Generate-token modal:

```
┌─ New API token ───────────────────────────────────────────┐
│                                                           │
│  Label   [_______________________________________]        │
│                                                           │
│           [ Cancel ]            [ Generate ]              │
└───────────────────────────────────────────────────────────┘
```

After Generate, the modal swaps to:

```
┌─ Token created ───────────────────────────────────────────┐
│                                                           │
│  Copy this token now. You won't see it again.             │
│                                                           │
│  ┌─────────────────────────────────────────────────┐ [📋] │
│  │ tk_8f2a_v8aQ3...x9                              │      │
│  └─────────────────────────────────────────────────┘      │
│                                                           │
│           [ Done ]                                        │
└───────────────────────────────────────────────────────────┘
```

Revoke is a confirm modal: "Revoke 'Android — Pixel 8'? Anything still
using this token will start getting 401."

## Implementation plan

- [ ] **`Termigate.Auth.ApiTokens` module** — pure functions over the
      `api_tokens` config list:
  - [ ] `list/0` → `[%{id, label, created_at, last_used_at}]` (no hash)
  - [ ] `create/1` (label) → `{:ok, %{record, plaintext_token}}`
  - [ ] `revoke/1` (id) → `:ok | {:error, :not_found}`
  - [ ] `verify/1` (token string) → `{:ok, id} | :error`
  - [ ] `record_use/1` (id) — debounced YAML write
- [ ] **`Termigate.Config`** — round-trip the new `api_tokens` list
      through `read_config / write_config`, with default `[]`.
- [ ] **`TermigateWeb.Plugs.RequireAuthToken`** — replace the inline
      `Phoenix.Token.verify` with `Auth.verify_bearer/1` that tries the
      three sources in order.
- [ ] **`TermigateWeb.SettingsLive`** — assigns + handlers:
  - [ ] `:api_tokens` assign loaded from `Auth.ApiTokens.list/0`
  - [ ] `:new_token_label`, `:new_token_plaintext` modal state
  - [ ] events: `new_token`, `generate_token`, `dismiss_token`,
        `confirm_revoke`, `revoke_token`
  - [ ] subscribe to `"config"` PubSub so revokes from another tab
        update the table live
- [ ] **`settings_live.html.heex`** — new section, two modals (create,
      reveal-once, confirm-revoke), styled to match existing cards.
- [ ] **Tests** in `test/termigate/auth/api_tokens_test.exs`:
  - [ ] create returns plaintext, persists hash, never persists plaintext
  - [ ] verify accepts created token, rejects tampered/unknown token
  - [ ] revoke removes record; subsequent verify fails
  - [ ] timing-safe verify (constant time on miss vs hit)
- [ ] **Plug tests** — `RequireAuthToken` accepts a UI-minted token,
      a legacy `Phoenix.Token`, and the env-var token; rejects junk.
- [ ] **LiveView tests** — generate, reveal once, dismiss, revoke,
      cross-tab live update.
- [ ] **Docs** — update `docs/APPLICATION_DESIGN.md` auth section and
      `CLAUDE.md` to mention the new `api_tokens` config block and the
      precedence order in `verify_bearer/1`.

## Open questions

1. **Should we expose `TERMIGATE_AUTH_TOKEN` in the UI as a read-only
   "Environment token" row?** Pro: operators see it exists. Con: it's
   plaintext in the env, surfacing it in the UI gives one more place
   to steal it from. **Recommendation: no.** Mention it in the help
   text under the table ("`TERMIGATE_AUTH_TOKEN` env var is also
   accepted as a bearer token if set.").

2. **Should revoking a token immediately disconnect open WebSocket
   channels (`terminal_channel`, `session_channel`) authenticated by
   that token?** Existing channels store the token at connect time
   and never re-verify. Re-checking on every channel push would add
   per-message overhead.
   **Recommendation: defer.** Document that revoke takes effect on the
   next HTTP request / next reconnect. Real attackers can't reconnect
   anyway once revoked. (Revisit if a use case appears for "kick the
   bad token *now*".)

3. **Token-rotation hint.** After 90 days unused, should the UI
   suggest revoking? Or auto-revoke at, say, 1 year?
   **Recommendation: v1 = nag in the UI ("last used 6 months ago"
   styled in muted yellow), v2 = configurable auto-revoke if anyone
   asks.**

4. **`last_used_at` write debouncing.** A burst of API calls writes
   the YAML up to once every 30s per token. Is that fine for SD cards
   / slow disks? Probably yes (config.yaml is tiny), but we should
   measure once a real Android app is hammering the API.

## Acceptance criteria

- Operator can: generate, copy, list, see-last-used, and revoke API
  tokens without restarting the container.
- A UI-minted token works as `Authorization: Bearer …` against every
  `/api/*` route exactly like a `/api/login`-minted token does today.
- Legacy `TERMIGATE_AUTH_TOKEN` and previously-issued
  `Phoenix.Token`-signed bearers continue to work.
- A revoked token returns 401 within one HTTP request of the revoke,
  measured from a fresh `curl`.
- All new tests pass; existing tests untouched.
