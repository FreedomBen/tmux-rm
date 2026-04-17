# MCP Server Design for termigate

## Overview

termigate exposes an MCP (Model Context Protocol) server that gives AI agents structured access to tmux sessions. Agents can manage sessions, execute commands, read terminal output, and monitor long-running processes — all through persistent, multiplexed terminal sessions with full auth.

The MCP server is a **separate transport layer** built on top of termigate's existing OTP infrastructure. It reuses TmuxManager, PaneStream, Config, and Auth directly — no new business logic is needed.

## Why MCP + termigate

Most AI agents get stateless shell access: run a command, get output, done. termigate via MCP provides **stateful, multiplexed terminal access**:

- **Session persistence** — processes survive between tool calls. Start a server, come back later, it's still running.
- **Multiplexing** — work in multiple panes simultaneously. Tail logs in one, run commands in another.
- **Bidirectional I/O** — not just command → output. Agents can interact with REPLs, respond to prompts, navigate TUIs.
- **Observability** — read what's on screen right now, including output from processes the agent didn't start.
- **Remote access** — termigate already handles auth and HTTP transport, so agents can reach machines behind firewalls.

## Design Principles

1. **Two tiers of tools.** Low-level tools map 1:1 to tmux operations. High-level tools compose them into agent-friendly workflows (e.g., "run command and wait for output"). Both tiers are always available.
2. **Reuse existing infrastructure.** Every MCP tool delegates to TmuxManager, PaneStream, or Config. No new business-logic state. The one exception is `mcp_session.ex`, a lightweight per-connection GenServer that tracks which PaneStream subscriptions and cleanup-pending sessions belong to each MCP client — it dies when the connection drops and holds no tmux state of its own.
3. **Treat terminal output as text.** MCP results are UTF-8 text. Binary terminal escapes are stripped or preserved based on a per-call flag. Default: stripped (clean text). Optional: raw (with ANSI escapes, for agents that can interpret them).
4. **Auth mirrors the REST API.** MCP connections authenticate the same way the REST API does — Bearer token via `Phoenix.Token`, verified by the same `RequireAuthToken` plug pipeline.
5. **No implicit side effects.** Tools that mutate state (create/kill sessions, send input) are clearly separated from read-only tools. Agents can safely call any read tool without changing tmux state.

## Transport

MCP supports multiple transports. termigate will implement **Streamable HTTP** (the current MCP standard), served from the existing Phoenix endpoint:

```
POST /mcp  — MCP JSON-RPC messages (request/response + notifications)
```

This reuses the existing HTTP server, TLS config, and auth pipeline. No additional ports or processes.

### Auth

MCP requests carry the same Bearer token used by the REST API:

```
Authorization: Bearer <token>
```

Token is obtained via `POST /api/login` (existing endpoint). The MCP endpoint runs through `RequireAuthToken` — same as all other API routes.

### Why not SSE or stdio?

- **SSE** is the legacy MCP transport. Streamable HTTP supersedes it and supports the same capabilities with a simpler connection model.
- **stdio** requires the MCP server to run as a local subprocess. termigate is a networked service — HTTP is the natural fit. Agents on other machines need network access anyway.

## Tool Design

### Tier 1: Low-Level Tools

These map directly to existing module functions. Each tool does one thing.

---

#### `tmux_list_sessions`

List all tmux sessions.

**Parameters:** none

**Returns:**
```json
{
  "sessions": [
    {
      "name": "dev",
      "windows": 3,
      "created": "2026-03-12T10:30:00Z",
      "attached": true
    }
  ]
}
```

**Delegates to:** `TmuxManager.list_sessions/0`

---

#### `tmux_list_panes`

List all panes in a session, grouped by window.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session` | string | yes | Session name |

**Returns:**
```json
{
  "windows": {
    "0": [
      {
        "target": "dev:0.0",
        "pane_id": "%0",
        "width": 120,
        "height": 40,
        "command": "vim"
      }
    ]
  }
}
```

**Delegates to:** `TmuxManager.list_panes/1`. The `Pane` struct has separate `session_name`, `window_index`, and `index` fields — the MCP handler constructs the `target` string as `"#{session_name}:#{window_index}.#{index}"`. Window index keys are integers in the Elixir map but serialize as string keys in JSON.

---

#### `tmux_create_session`

Create a new tmux session.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | yes | Session name (alphanumeric, hyphens, underscores) |
| `command` | string | no | Initial command to run |
| `cols` | integer | no | Initial width (default: 120) |
| `rows` | integer | no | Initial height (default: 40) |

**Returns:**
```json
{
  "name": "build",
  "target": "build:0.0"
}
```

**Delegates to:** `TmuxManager.create_session/2` (returns `{:ok, %{name: name}}`). The MCP handler constructs the target string as `"<name>:0.0"` since new sessions always start with one window and one pane.

---

#### `tmux_kill_session`

Kill a tmux session and all its processes.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | yes | Session name |

**Delegates to:** `TmuxManager.kill_session/1`

---

#### `tmux_split_pane`

Split an existing pane.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target (e.g., `"dev:0.0"`) |
| `direction` | string | no | `"horizontal"` (side-by-side panes) or `"vertical"` (top/bottom panes). Default: `"horizontal"`. Matches tmux `-h`/`-v` semantics. |

**Returns:**
```json
{
  "new_target": "dev:0.1"
}
```

**Delegates to:** `TmuxManager.split_pane/2` (returns raw tmux output). The MCP handler calls `TmuxManager.list_panes/1` after splitting to determine the new pane's target.

---

#### `tmux_kill_pane`

Kill a single pane.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |

**Delegates to:** `TmuxManager.kill_pane/1`

---

#### `tmux_send_keys`

Send raw input to a pane. This is literal keystroke data — what the terminal receives.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `data` | string | yes | Input text (e.g., `"ls -la\n"`) |

Use `\n` for Enter, `\t` for Tab, `\x03` for Ctrl-C, etc.

**Delegates to:** `PaneStream.send_keys/2`

---

#### `tmux_read_pane`

Read the current visible content of a pane (what's on screen now).

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `raw` | boolean | no | Include ANSI escape sequences (default: `false`) |

**Returns:**
```json
{
  "content": "user@host:~/project$ ls -la\ntotal 42\ndrwxr-xr-x ...",
  "width": 120,
  "height": 40
}
```

**Implementation:** Calls `tmux capture-pane -p -t <target>` (optionally with `-e` for escapes). Requires a new public `TmuxManager.capture_pane/2` function. The command is already used internally in `PaneStream` (`capture_scrollback/2`, `resize_and_capture`) — this just exposes it as a standalone function.

---

#### `tmux_read_history`

Read the scrollback buffer for a pane. Returns more content than `read_pane` (which only shows the visible screen).

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `lines` | integer | no | Number of scrollback lines (default: 1000, max: 10000) |
| `raw` | boolean | no | Include ANSI escapes (default: `false`) |

**Returns:**
```json
{
  "content": "...",
  "line_count": 847
}
```

**Implementation:** Two paths depending on whether a PaneStream is active for this target:
- **PaneStream active:** Read from the RingBuffer via a new `PaneStream.read_buffer/1` function (a simple `GenServer.call` that returns `RingBuffer.read(state.buffer)` without triggering viewer lifecycle — no monitors, grace timers, or PubSub subscriptions). Strip ANSI unless `raw: true`.
- **No PaneStream:** Fall back to `tmux capture-pane -p -S -<lines> -t <target>`.

---

#### `tmux_resize_pane`

Resize a pane.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `cols` | integer | yes | Width (1–500) |
| `rows` | integer | yes | Height (1–200) |

**Delegates to:** `TmuxManager.resize_pane/2` (maps `cols` → `x:`, `rows` → `y:` keyword opts)

---

### Tier 2: High-Level Tools

These compose Tier 1 operations into workflows optimized for agent use.

---

#### `tmux_run_command`

Run a command in a pane and return the output. This is the primary tool most agents will use.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `command` | string | yes | Shell command to run |
| `timeout_ms` | integer | no | Max wait time (default: 30000, max: 300000) |
| `raw` | boolean | no | Include ANSI escapes in output (default: `false`) |

**Behavior:**

1. Subscribe to PaneStream output for `target`.
2. Inject a unique marker: send `<command>; echo __MCP_DONE_<uuid>_$?__\n` so the marker contains the exit code.
3. Stream output, buffering everything after the command echo.
4. When the marker appears in output, capture everything between command echo and marker.
5. Unsubscribe and return captured output.
6. If timeout expires before marker, return what was captured so far with `"timed_out": true`.

**Returns:**
```json
{
  "output": "total 42\ndrwxr-xr-x 5 user user 4096 Mar 12 10:30 .\n...",
  "exit_code": 0,
  "timed_out": false
}
```

**Exit code capture:** The `$?` in the marker expands to the previous command's exit code, so the marker doubles as exit status delivery.

**Edge cases:**
- If the pane is running an interactive program (vim, python REPL), the marker approach won't work cleanly. The agent should use `send_keys` + `read_pane` instead. `run_command` is for shell prompts.
- If the command itself outputs the marker string (astronomically unlikely with UUID), the tool may return early with partial output.

---

#### `tmux_run_command_in_new_session`

Create a new session, run a command, and return the output. Convenience wrapper for one-shot tasks.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `command` | string | yes | Shell command to run |
| `session_name` | string | no | Session name (auto-generated if omitted) |
| `timeout_ms` | integer | no | Max wait time (default: 30000) |
| `cleanup` | boolean | no | Kill session after command completes (default: `true`) |
| `raw` | boolean | no | Include ANSI escapes (default: `false`) |

**Behavior:**

1. Create session with `tmux_create_session` (name auto-generated as `mcp-<short-uuid>` if not provided).
2. Run command with `tmux_run_command` on the session's initial pane.
3. If `cleanup: true`, kill session after command completes.
4. Return combined result.

**Returns:**
```json
{
  "session": "mcp-a1b2c3",
  "target": "mcp-a1b2c3:0.0",
  "output": "...",
  "exit_code": 0,
  "timed_out": false,
  "cleaned_up": true
}
```

---

#### `tmux_wait_for_output`

Watch a pane and return when a pattern appears in the output, or timeout.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `pattern` | string | yes | Regex pattern to match against output |
| `timeout_ms` | integer | no | Max wait time (default: 60000, max: 300000) |
| `raw` | boolean | no | Include ANSI escapes (default: `false`) |

**Behavior:**

1. Subscribe to PaneStream for `target`.
2. First check existing scrollback/screen content for the pattern.
3. If not found, watch incoming output for a match.
4. On match, return the matching line(s) and surrounding context (5 lines before/after).
5. On timeout, return what was captured with `"timed_out": true`.

**Returns:**
```json
{
  "matched": true,
  "match": "Server running at http://localhost:8888",
  "context": "...\nCompiling 42 files (.ex)\nServer running at http://localhost:8888\n...",
  "timed_out": false
}
```

**Use case:** Start a dev server with `send_keys`, then `wait_for_output` with pattern `"Server running"` to know when it's ready.

---

#### `tmux_send_and_read`

Send input to a pane and read the screen content after a short delay. Simpler than `run_command` — works with any interactive program, not just shell prompts.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `target` | string | yes | Pane target |
| `data` | string | yes | Input to send |
| `delay_ms` | integer | no | Wait before reading (default: 500, max: 10000) |
| `raw` | boolean | no | Include ANSI escapes (default: `false`) |

**Behavior:**

1. Send input via `PaneStream.send_keys/2`.
2. Wait `delay_ms` for output to settle.
3. Read pane content via `tmux capture-pane`.
4. Return screen content.

**Returns:**
```json
{
  "content": ">>> 2 + 2\n4\n>>> "
}
```

**Use case:** Interacting with REPLs, TUI applications, or any context where marker-based output capture won't work.

---

### Tool Summary

| Tool | Tier | Mutates | Description |
|------|------|---------|-------------|
| `tmux_list_sessions` | 1 | no | List sessions |
| `tmux_list_panes` | 1 | no | List panes in session |
| `tmux_create_session` | 1 | yes | Create session |
| `tmux_kill_session` | 1 | yes | Kill session |
| `tmux_split_pane` | 1 | yes | Split pane |
| `tmux_kill_pane` | 1 | yes | Kill pane |
| `tmux_send_keys` | 1 | yes | Send raw input |
| `tmux_read_pane` | 1 | no | Read visible screen |
| `tmux_read_history` | 1 | no | Read scrollback buffer |
| `tmux_resize_pane` | 1 | yes | Resize pane |
| `tmux_run_command` | 2 | yes | Run command, return output |
| `tmux_run_command_in_new_session` | 2 | yes | Create session + run command |
| `tmux_wait_for_output` | 2 | no | Watch for pattern in output |
| `tmux_send_and_read` | 2 | yes | Send input + read screen |

## Resources

MCP resources provide read-only data that agents can pull into their context. termigate exposes:

#### `tmux://sessions`

Current session list. Equivalent to `tmux_list_sessions` but available as a pollable resource.

#### `tmux://session/{name}/panes`

Pane layout for a session. Equivalent to `tmux_list_panes`.

#### `tmux://pane/{target}/screen`

Current visible screen content for a pane. Equivalent to `tmux_read_pane`.

These are simple read-only mirrors of the tool equivalents. Their value is in MCP clients that auto-refresh resources in the background — the agent's context stays current without explicit tool calls.

## Implementation Plan

### Module Structure

```
lib/termigate_web/mcp/
├── mcp_controller.ex        # HTTP endpoint, JSON-RPC dispatch
├── mcp_tools.ex             # Tool definitions (name, schema, descriptions)
├── mcp_tool_handler.ex      # Tool execution (dispatches to TmuxManager/PaneStream)
├── mcp_resources.ex         # Resource definitions and handlers
└── mcp_session.ex           # Per-connection state (active subscriptions, cleanup)
```

Auth is handled by the `RequireAuthToken` plug in the route pipeline — no separate MCP auth module is needed.

### New Route

```elixir
# router.ex
scope "/mcp", TermigateWeb.MCP do
  pipe_through [:api, :require_auth_token]
  post "/", MCPController, :handle
end
```

### Dependencies

**Option A: Build from scratch.** MCP over Streamable HTTP is a thin JSON-RPC layer. The protocol is small enough that a purpose-built handler in `mcp_controller.ex` is reasonable. termigate already handles WebSocket streaming; HTTP SSE for notifications is similar.

**Option B: Use an Elixir MCP library.** If a mature library exists at implementation time (e.g., `mcp_ex`, `ex_mcp`), use it for protocol handling and provide tool/resource implementations as callbacks. This is preferred if the library is stable — protocol details (JSON-RPC framing, capability negotiation, error codes) are tedious to get right.

Evaluate at implementation time. The tool and resource definitions above are transport-agnostic — they work with either approach.

### ANSI Stripping

The `raw: false` default strips ANSI escape sequences from output. Implementation: a simple regex pass that removes `\x1b\[[0-9;]*[a-zA-Z]` and other common CSI/OSC sequences. This runs in `mcp_tool_handler.ex` before returning results — no changes to PaneStream or TmuxManager.

### Cleanup

MCP sessions should track resources they create. When a connection drops:

- Unsubscribe from any active PaneStream subscriptions.
- Optionally kill sessions created with `cleanup: true` that are still running.

`mcp_session.ex` is a lightweight GenServer, one per MCP connection. It starts on the first request for a given `Mcp-Session-Id` header (per Streamable HTTP spec) and is supervised under a DynamicSupervisor. It dies when the client sends a `DELETE /mcp` session teardown or after an inactivity timeout. It holds no tmux state — only a list of PaneStream subscriptions and pending-cleanup session names.

### Rate Limiting

The MCP route will use `RateLimitStore` with MCP-specific limits. Default: 120 requests/minute per IP (2/sec sustained). This is a single rate limit on the `/mcp` endpoint — no per-tool differentiation initially. The limit is higher than the login endpoint (5/60s) because agents make many rapid tool calls in normal use. Can be tightened or split per-tool later if needed.

## Example Agent Workflows

### 1. Run tests and fix failures

```
→ tmux_run_command_in_new_session(command: "cd server && mix test", timeout_ms: 120000)
← {output: "...\n3 tests failed\n...", exit_code: 1}
  [agent reads failures, edits code]
→ tmux_run_command_in_new_session(command: "cd server && mix test test/specific_test.exs", timeout_ms: 60000)
← {output: "3 tests, 3 passed", exit_code: 0}
```

### 2. Start server, wait for ready, then test

```
→ tmux_create_session(name: "dev-server")
← {target: "dev-server:0.0"}
→ tmux_send_keys(target: "dev-server:0.0", data: "cd server && mix phx.server\n")
→ tmux_wait_for_output(target: "dev-server:0.0", pattern: "Running.*endpoint", timeout_ms: 30000)
← {matched: true, match: "Running TermigateWeb.Endpoint with Bandit at http://localhost:8888"}
→ tmux_run_command_in_new_session(command: "curl -s localhost:8888/healthz")
← {output: "ok", exit_code: 0}
→ tmux_kill_session(name: "dev-server")
```

### 3. Interactive debugging with iex

```
→ tmux_create_session(name: "debug", command: "cd server && iex -S mix")
← {target: "debug:0.0"}
→ tmux_wait_for_output(target: "debug:0.0", pattern: "iex\\(1\\)>", timeout_ms: 15000)
← {matched: true}
→ tmux_send_and_read(target: "debug:0.0", data: "Termigate.TmuxManager.list_sessions()\n", delay_ms: 1000)
← {content: "iex(1)> Termigate.TmuxManager.list_sessions()\n{:ok, [%Termigate.Tmux.Session{name: \"debug\", ...}]}\niex(2)> "}
→ tmux_kill_session(name: "debug")
```

### 4. Multi-pane monitoring

```
→ tmux_create_session(name: "monitor")
← {target: "monitor:0.0"}
→ tmux_send_keys(target: "monitor:0.0", data: "tail -f /var/log/app.log\n")
→ tmux_split_pane(target: "monitor:0.0", direction: "vertical")
← {new_target: "monitor:0.1"}
→ tmux_send_keys(target: "monitor:0.1", data: "htop\n")
  [later]
→ tmux_read_pane(target: "monitor:0.0")
← {content: "2026-03-12 10:45:01 [ERROR] Connection refused..."}
→ tmux_read_pane(target: "monitor:0.1")
← {content: "  PID USER  ... 89.2% ruby app.rb ..."}
```

## Future Considerations

**Notifications/subscriptions.** MCP supports server-initiated notifications. A natural extension: subscribe to pane output as a stream of notifications rather than polling with `read_pane`. This requires SSE or WebSocket upgrade on the MCP transport. Not in initial scope — polling with `wait_for_output` covers the main use case.

**Tool annotations.** MCP tool annotations (`readOnlyHint`, `destructiveHint`, `openWorldHint`) should be set accurately. All Tier 1 read tools get `readOnlyHint: true`. Kill operations get `destructiveHint: true`. This helps agents make safer autonomous decisions.

**Prompt templates.** MCP supports server-provided prompt templates. termigate could offer prompts like "debug this failing command" or "set up a dev environment" that guide agents through multi-step workflows. Low priority — agents generally bring their own prompting.

**Quick actions via MCP.** Expose quick actions as tools: `tmux_list_quick_actions`, `tmux_run_quick_action(id, target)`. Lets agents trigger the same one-click actions humans use in the UI. Simple to implement — delegates to Config + PaneStream.
