# Telemetry and Observability

AgentSessionManager emits telemetry events and supports audit logging for production observability. Both systems can be enabled or disabled at runtime.

## Telemetry Events

All telemetry events use the `:telemetry` library and follow the `[:agent_session_manager, ...]` prefix.

### Run Lifecycle Events

#### `[:agent_session_manager, :run, :start]`

Emitted when a run begins.

| Measurement | Type | Description |
|---|---|---|
| `system_time` | integer | System time in native units |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `agent_id` | string | Agent identifier |
| `run` | Run.t() | Full run struct |
| `session` | Session.t() | Full session struct |

#### `[:agent_session_manager, :run, :stop]`

Emitted when a run completes successfully.

| Measurement | Type | Description |
|---|---|---|
| `duration` | integer | Duration in nanoseconds |
| `system_time` | integer | System time |
| `input_tokens` | integer | Input token count (if available) |
| `output_tokens` | integer | Output token count (if available) |
| `total_tokens` | integer | Total token count (if available) |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `agent_id` | string | Agent identifier |
| `status` | atom | Final run status |
| `run` | Run.t() | Full run struct |
| `session` | Session.t() | Full session struct |

#### `[:agent_session_manager, :run, :exception]`

Emitted when a run fails.

| Measurement | Type | Description |
|---|---|---|
| `duration` | integer | Duration in nanoseconds |
| `system_time` | integer | System time |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `agent_id` | string | Agent identifier |
| `error_code` | atom | Error code |
| `error_message` | string | Error message |
| `run` | Run.t() | Full run struct |
| `session` | Session.t() | Full session struct |
| `error` | map | Full error details |

### Usage Events

#### `[:agent_session_manager, :usage, :report]`

Emitted with token usage metrics.

| Measurement | Type | Description |
|---|---|---|
| (varies) | number | All keys from the metrics map |

Common measurement keys: `input_tokens`, `output_tokens`, `total_tokens`, `cost_usd`.

### Adapter Events

#### `[:agent_session_manager, :adapter, <event_type>]`

Emitted for each adapter event (`:run_started`, `:message_streamed`, `:tool_call_started`, etc.).

| Measurement | Type | Description |
|---|---|---|
| `system_time` | integer | System time |
| (numeric data) | number | Any numeric values from event data |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `agent_id` | string | Agent identifier |
| `provider` | atom | Provider name (`:claude`, `:codex`) |
| `tool_name` | string | Tool name (for tool events) |
| `event_data` | map | Full event data |

## Attaching Handlers

```elixir
:telemetry.attach_many(
  "my-metrics",
  [
    [:agent_session_manager, :run, :start],
    [:agent_session_manager, :run, :stop],
    [:agent_session_manager, :run, :exception],
    [:agent_session_manager, :usage, :report]
  ],
  &MyMetricsHandler.handle_event/4,
  nil
)
```

### Example: Logging Handler

```elixir
defmodule MyMetricsHandler do
  require Logger

  def handle_event([:agent_session_manager, :run, :start], _measurements, metadata, _config) do
    Logger.info("Run started: #{metadata.run_id} (agent: #{metadata.agent_id})")
  end

  def handle_event([:agent_session_manager, :run, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :nanosecond, :millisecond)
    Logger.info("Run completed: #{metadata.run_id} in #{duration_ms}ms")
  end

  def handle_event([:agent_session_manager, :run, :exception], _measurements, metadata, _config) do
    Logger.error("Run failed: #{metadata.run_id} - #{metadata.error_message}")
  end

  def handle_event([:agent_session_manager, :usage, :report], measurements, metadata, _config) do
    Logger.info("Usage for #{metadata.session_id}: #{inspect(measurements)}")
  end
end
```

## The Span Helper

For manual execution, the `span/3` function wraps a function with automatic start/stop/exception events:

```elixir
alias AgentSessionManager.Telemetry

result = Telemetry.span(run, session, fn ->
  # Your execution logic
  {:ok, %{output: output, token_usage: usage}}
end)
```

This automatically emits:
- `:start` before the function runs
- `:stop` if the function returns `{:ok, ...}`
- `:exception` if the function returns `{:error, ...}`

## Enabling/Disabling Telemetry

Telemetry uses the `AgentSessionManager.Config` layered configuration system. `set_enabled/1` sets a **process-local** override, so disabling telemetry in one process (e.g., a test) does not affect other processes.

```elixir
# Check if enabled (default: true)
Telemetry.enabled?()

# Disable for the current process only
Telemetry.set_enabled(false)

# Or via application config (affects all processes without a local override)
config :agent_session_manager, telemetry_enabled: false
```

When disabled, telemetry functions return `:ok` without emitting events. See [Configuration](configuration.md) for details on the layered resolution order.

## Audit Logging

The `AuditLogger` module persists audit events to the `SessionStore`, providing a queryable history of all run lifecycle events.

### What Gets Logged

- `:run_started` -- when a run begins
- `:run_completed` -- when a run finishes successfully (includes token usage)
- `:run_failed` -- when a run fails (includes error code and message)
- `:error_occurred` -- when an error happens during execution
- `:token_usage_updated` -- when usage metrics are reported

### Manual Logging

```elixir
alias AgentSessionManager.AuditLogger

AuditLogger.log_run_started(store, run, session)
AuditLogger.log_run_completed(store, run, session, %{token_usage: usage})
AuditLogger.log_run_failed(store, run, session, %{code: :timeout, message: "Timed out"})
AuditLogger.log_error(store, run, session, %{code: :provider_error, message: "Rate limited"})
AuditLogger.log_usage_metrics(store, session, %{input_tokens: 100}, run_id: run.id)
```

### Querying the Audit Log

```elixir
{:ok, events} = AuditLogger.get_audit_log(store, session.id)
{:ok, events} = AuditLogger.get_audit_log(store, session.id, run_id: run.id)
{:ok, events} = AuditLogger.get_audit_log(store, session.id, type: :run_failed)
```

### Automatic Logging via Telemetry

The AuditLogger can automatically create audit entries from telemetry events:

```elixir
# Attach -- audit events are now created automatically for all runs
AuditLogger.attach_telemetry_handlers(store)

# Detach when no longer needed
AuditLogger.detach_telemetry_handlers()
```

This is the recommended approach for production: telemetry handles real-time metrics, and the audit logger ensures every event is durably stored.

### Enabling/Disabling Audit Logging

Audit logging also uses the `AgentSessionManager.Config` layered system. `set_enabled/1` sets a **process-local** override.

```elixir
AuditLogger.enabled?()           # default: true
AuditLogger.set_enabled(false)   # disable for the current process

# Or via application config (affects all processes without a local override)
config :agent_session_manager, audit_logging_enabled: false
```

See [Configuration](configuration.md) for the full resolution order.

## Routing Telemetry Events

The `ProviderRouter` emits telemetry events for each routing attempt, enabling
observability into provider selection, failover, and latency.

#### `[:agent_session_manager, :router, :attempt, :start]`

Emitted before adapter execution begins for a routing attempt.

| Measurement | Type | Description |
|---|---|---|
| `system_time` | integer | System time in native units |

| Metadata | Type | Description |
|---|---|---|
| `adapter_id` | string | Selected adapter identifier |
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `attempt` | integer | Attempt number (1-based) |
| `strategy` | atom | Routing strategy (`:prefer` or `:weighted`) |
| `candidates` | list | Candidate adapter IDs considered |

#### `[:agent_session_manager, :router, :attempt, :stop]`

Emitted after a successful adapter execution.

| Measurement | Type | Description |
|---|---|---|
| `duration` | integer | Duration in nanoseconds |
| `system_time` | integer | System time |

| Metadata | Type | Description |
|---|---|---|
| `adapter_id` | string | Adapter that handled the run |
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `attempt` | integer | Attempt number |

#### `[:agent_session_manager, :router, :attempt, :exception]`

Emitted when an adapter execution fails during routing.

| Measurement | Type | Description |
|---|---|---|
| `duration` | integer | Duration in nanoseconds |
| `system_time` | integer | System time |

| Metadata | Type | Description |
|---|---|---|
| `adapter_id` | string | Adapter that failed |
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `attempt` | integer | Attempt number |
| `error_code` | atom | Error code from the failure |
| `retryable` | boolean | Whether the error is retryable |
| `will_retry` | boolean | Whether the router will try another adapter |

### Attaching Router Handlers

```elixir
:telemetry.attach_many(
  "my-routing-metrics",
  [
    [:agent_session_manager, :router, :attempt, :start],
    [:agent_session_manager, :router, :attempt, :stop],
    [:agent_session_manager, :router, :attempt, :exception]
  ],
  &MyRoutingHandler.handle_event/4,
  nil
)
```

## Runtime Telemetry Events

The `SessionServer` runtime emits telemetry events under the
`[:agent_session_manager, :runtime, ...]` namespace for queue and lifecycle
observability.

#### `[:agent_session_manager, :runtime, :run, :enqueued]`

Emitted when a run is submitted to the queue.

| Measurement | Type | Description |
|---|---|---|
| `system_time` | integer | System time |
| `queue_depth` | integer | Queue size after enqueue |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `in_flight_count` | integer | Current in-flight runs |
| `max_concurrent_runs` | integer | Configured slot limit |

#### `[:agent_session_manager, :runtime, :run, :started]`

Emitted when a run is dequeued and adapter execution begins.

| Measurement | Type | Description |
|---|---|---|
| `system_time` | integer | System time |
| `wait_time` | integer | Time in queue (nanoseconds) |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `in_flight_count` | integer | In-flight runs after start |

#### `[:agent_session_manager, :runtime, :run, :completed]`

Emitted when a run finishes (success, failure, or cancellation).

| Measurement | Type | Description |
|---|---|---|
| `duration` | integer | Total run duration (nanoseconds) |
| `system_time` | integer | System time |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `status` | atom | Final status (`:completed`, `:failed`, `:cancelled`) |
| `in_flight_count` | integer | In-flight runs after completion |
| `queued_count` | integer | Remaining queued runs |

#### `[:agent_session_manager, :runtime, :run, :crashed]`

Emitted when a run task crashes unexpectedly.

| Measurement | Type | Description |
|---|---|---|
| `system_time` | integer | System time |

| Metadata | Type | Description |
|---|---|---|
| `run_id` | string | Run identifier |
| `session_id` | string | Session identifier |
| `reason` | term | Crash reason from the DOWN message |

#### `[:agent_session_manager, :runtime, :drain, :complete]`

Emitted when `drain/2` finishes successfully.

| Measurement | Type | Description |
|---|---|---|
| `duration` | integer | Total drain wait time (nanoseconds) |
| `system_time` | integer | System time |

| Metadata | Type | Description |
|---|---|---|
| `session_id` | string | Session identifier |
| `runs_drained` | integer | Total runs that completed during drain |

### Attaching Runtime Handlers

```elixir
:telemetry.attach_many(
  "my-runtime-metrics",
  [
    [:agent_session_manager, :runtime, :run, :enqueued],
    [:agent_session_manager, :runtime, :run, :started],
    [:agent_session_manager, :runtime, :run, :completed],
    [:agent_session_manager, :runtime, :run, :crashed],
    [:agent_session_manager, :runtime, :drain, :complete]
  ],
  &MyRuntimeHandler.handle_event/4,
  nil
)
```
