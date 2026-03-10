# Phase 15: Observability & Monitoring

## Goal
Wire up the Telemetry dependencies (added in Phase 1) into actionable metrics, structured logging, and a metrics endpoint. After this phase, operators can monitor application health, diagnose performance issues, and integrate with external monitoring systems.

## Dependencies
- Phase 14 complete (deployment infrastructure)
- `telemetry_metrics` and `telemetry_poller` dependencies (Phase 1)

**Implementation note**: While this phase is listed last, the `RemoteCodeAgents.Telemetry` supervisor should be added to the supervision tree during **Phase 1** (it's just a supervisor with telemetry_poller — no deps on other phases). Then, as each subsequent phase is built, add the `:telemetry.execute/3` calls inline (step 15.5 lists them all). This phase formalizes the metrics endpoint, structured logging, and health check enrichment — but the instrumentation itself should be incremental.

## Steps

### 15.1 Telemetry Event Definitions

Define custom Telemetry events emitted throughout the application:

**PaneStream events** (`[:remote_code_agents, :pane_stream, *]`):
- `[:pane_stream, :start]` — PaneStream started (metadata: target, pane_id)
- `[:pane_stream, :stop]` — PaneStream stopped (metadata: target, reason, duration_ms)
- `[:pane_stream, :output]` — Output flushed (measurements: bytes, metadata: target)
- `[:pane_stream, :input]` — Input sent (measurements: bytes, metadata: target)
- `[:pane_stream, :viewer_change]` — Viewer count changed (measurements: count, metadata: target)
- `[:pane_stream, :recovery]` — Port crash recovery attempted (metadata: target, attempt)

**Auth events** (`[:remote_code_agents, :auth, *]`):
- `[:auth, :login, :success]` — (metadata: username, ip)
- `[:auth, :login, :failure]` — (metadata: username, ip)
- `[:auth, :rate_limited]` — (metadata: ip, endpoint_key)

**SessionPoller events** (`[:remote_code_agents, :session_poller, *]`):
- `[:session_poller, :poll]` — Poll completed (measurements: duration_ms, session_count)

### 15.2 Telemetry Module

**`lib/remote_code_agents/telemetry.ex`**:

```elixir
defmodule RemoteCodeAgents.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # PaneStream
      counter("remote_code_agents.pane_stream.start.total"),
      counter("remote_code_agents.pane_stream.stop.total", tag_values: fn m -> %{reason: m.reason} end),
      sum("remote_code_agents.pane_stream.output.bytes"),
      sum("remote_code_agents.pane_stream.input.bytes"),
      last_value("remote_code_agents.pane_stream.viewer_change.count"),
      counter("remote_code_agents.pane_stream.recovery.total"),

      # Auth
      counter("remote_code_agents.auth.login.success.total"),
      counter("remote_code_agents.auth.login.failure.total"),
      counter("remote_code_agents.auth.rate_limited.total"),

      # SessionPoller
      summary("remote_code_agents.session_poller.poll.duration_ms"),
      last_value("remote_code_agents.session_poller.poll.session_count"),

      # VM metrics (from telemetry_poller)
      last_value("vm.memory.total"),
      last_value("vm.memory.processes"),
      last_value("vm.memory.binary"),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.system_counts.process_count"),
    ]
  end

  defp periodic_measurements do
    [
      # Active PaneStream count
      {__MODULE__, :pane_stream_count, []},
      # Rate limit table size
      {__MODULE__, :rate_limit_table_size, []}
    ]
  end

  def pane_stream_count do
    count = DynamicSupervisor.count_children(RemoteCodeAgents.PaneStreamSupervisor)[:active] || 0
    :telemetry.execute([:remote_code_agents, :pane_streams], %{active: count}, %{})
  end

  def rate_limit_table_size do
    size = :ets.info(:rate_limit_store, :size) || 0
    :telemetry.execute([:remote_code_agents, :rate_limit_store], %{size: size}, %{})
  end
end
```

### 15.3 Metrics Endpoint

**`lib/remote_code_agents_web/controllers/metrics_controller.ex`**:

- `GET /metrics` — returns metrics in JSON format
- Unauthenticated (like `/healthz`) — operators need metrics without app credentials
- Optionally protected by a separate `RCA_METRICS_TOKEN` env var (bearer token check, no-op if unset)
- Returns: active PaneStreams, total viewers, VM memory, process count, uptime, auth failure count

**Alternatively**, if Prometheus integration is desired:
- Add `{:telemetry_metrics_prometheus, "~> 1.1"}` to deps
- Expose `/metrics` in Prometheus text format
- This is optional — the JSON endpoint works standalone

### 15.4 Structured Logging

Ensure all log statements across the application use structured metadata via `Logger.metadata/1` and keyword list messages for machine-parseable output:

```elixir
# Instead of:
Logger.info("PaneStream started for #{target}")

# Use:
Logger.info("PaneStream started", target: target, pane_id: pane_id)
```

Configure production log format in `config/runtime.exs`:
```elixir
config :logger, :default_handler,
  config: [
    type: :standard_io
  ]

# Optional: JSON log format for log aggregation
# Add {:logger_json, "~> 6.0"} to deps if needed
```

### 15.5 Emit Telemetry in Existing Modules

Add `:telemetry.execute/3` calls to the modules built in prior phases. This is a thin instrumentation layer — one line per event, no structural changes:

- **PaneStream** (`pane_stream.ex`): emit on start, stop, output flush, input, viewer change, recovery
- **Auth** (`auth.ex`): emit on login success/failure
- **RateLimitStore** (`rate_limit_store.ex`): emit on rate limit exceeded
- **SessionPoller** (`session_poller.ex`): emit on poll with duration and session count

### 15.6 Health Check Enhancement

Update `/healthz` (from Phase 4) to include richer diagnostics:

```json
{
  "status": "ok",
  "tmux": "ok",
  "tmux_version": "3.4",
  "active_pane_streams": 3,
  "total_viewers": 7,
  "uptime_seconds": 86400,
  "vm_memory_mb": 128,
  "auth_mode": "bcrypt"
}
```

### 15.7 Supervision Tree

Add `RemoteCodeAgents.Telemetry` to the supervision tree in `application.ex` (early, before other children so metrics are available from boot):

```elixir
children = [
  RemoteCodeAgents.Telemetry,
  # ... existing children ...
]
```

### 15.8 Tests

- Telemetry events: attach test handlers, trigger actions, verify events emitted with correct measurements/metadata
- Metrics endpoint: verify JSON response structure
- Health check: verify enriched response fields

## Files Created/Modified
```
lib/remote_code_agents/telemetry.ex
lib/remote_code_agents_web/controllers/metrics_controller.ex
lib/remote_code_agents/application.ex (add Telemetry supervisor)
lib/remote_code_agents/pane_stream.ex (add telemetry calls)
lib/remote_code_agents/auth.ex (add telemetry calls)
lib/remote_code_agents/session_poller.ex (add telemetry calls)
lib/remote_code_agents_web/rate_limit_store.ex (add telemetry calls)
lib/remote_code_agents_web/controllers/health_controller.ex (enrich response)
lib/remote_code_agents_web/router.ex (add /metrics route)
config/runtime.exs (structured logging config)
test/remote_code_agents/telemetry_test.exs
test/remote_code_agents_web/controllers/metrics_controller_test.exs
```

## Exit Criteria
- Telemetry events emitted for PaneStream lifecycle, auth, and polling
- `GET /metrics` returns JSON with active streams, viewers, VM stats, uptime
- `GET /healthz` returns enriched status including tmux version and stream counts
- Structured log metadata attached to all key log statements
- `telemetry_poller` periodically measures active PaneStreams and rate limit table size
- VM metrics (memory, process count, run queue) available via metrics endpoint
- All telemetry tests pass
