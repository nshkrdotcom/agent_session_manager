# Configuration Reference

All operational defaults in AgentSessionManager are managed through `AgentSessionManager.Config`. This module provides a single source of truth for every timeout, limit, buffer size, and tuning parameter used throughout the library.

## How Configuration Works

Every call to `AgentSessionManager.Config.get/1` resolves a value through three layers, in priority order:

1. **Process-local override** - set via `AgentSessionManager.Config.put/2`, scoped to the calling process. Automatically cleaned up when the process exits.
2. **Application environment** - set via `config :agent_session_manager, key: value` or `Application.put_env/3`.
3. **Built-in default** - hardcoded fallback.

```text
Config.get(:command_timeout_ms)
  |
  |-- Process dictionary has override? --> return override
  |-- Application.get_env has value?   --> return app env value
  |-- Return built-in default (30_000)
```

This layering follows the same pattern as Elixir's `Logger` for per-process log levels and enables fully concurrent (`async: true`) testing.

## Application Config Example

Override any default in `config/config.exs` or `config/runtime.exs`:

```elixir
# config/config.exs
config :agent_session_manager,
  command_timeout_ms: 60_000,
  max_parallel_sessions: 200,
  event_buffer_size: 5_000
```

## Process-Local Overrides (for Testing)

```elixir
# In a test - only affects the current process
AgentSessionManager.Config.put(:command_timeout_ms, 1_000)
assert AgentSessionManager.Config.get(:command_timeout_ms) == 1_000

# Remove override (falls back to app env / default)
AgentSessionManager.Config.delete(:command_timeout_ms)
```

## Complete Key Reference

### Feature Flags

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:telemetry_enabled` | `boolean` | `true` | Enable/disable telemetry event emission |
| `:audit_logging_enabled` | `boolean` | `true` | Enable/disable audit logging |

### Timeouts

All timeout values are in milliseconds.

| Key | Default | Description |
|-----|---------|-------------|
| `:stream_idle_timeout_ms` | `120_000` | StreamSession idle timeout before auto-close |
| `:task_shutdown_timeout_ms` | `5_000` | StreamSession task shutdown grace period |
| `:await_run_timeout_ms` | `60_000` | SessionServer timeout for awaiting run completion |
| `:drain_timeout_buffer_ms` | `1_000` | Extra buffer added to SessionServer drain timeout |
| `:command_timeout_ms` | `30_000` | Shell command execution timeout (Exec + ShellAdapter) |
| `:execute_timeout_ms` | `60_000` | ProviderAdapter execute call timeout |
| `:execute_grace_timeout_ms` | `5_000` | Grace period added on top of execute timeout |
| `:circuit_breaker_cooldown_ms` | `30_000` | Circuit breaker open-to-half-open cooldown |
| `:sticky_session_ttl_ms` | `300_000` | Sticky session routing TTL |
| `:event_stream_poll_interval_ms` | `250` | Poll interval when no new events in stream |
| `:genserver_call_timeout_ms` | `5_000` | Default GenServer.call timeout for store/adapter dispatch |

### Buffer and Memory Limits

| Key | Default | Description |
|-----|---------|-------------|
| `:event_buffer_size` | `1_000` | Max events held in-memory in EventStream |
| `:max_output_bytes` | `1_048_576` | Max captured shell command output (1 MB) |
| `:max_patch_bytes` | `1_048_576` | Max git diff patch size (1 MB) |
| `:error_text_max_bytes` | `16_384` | Max bytes retained in `provider_error.stderr` before emission/persistence |
| `:error_text_max_lines` | `200` | Max lines retained in `provider_error.stderr` before emission/persistence |

### Concurrency

| Key | Default | Description |
|-----|---------|-------------|
| `:max_parallel_sessions` | `100` | ConcurrencyLimiter max parallel sessions |
| `:max_parallel_runs` | `50` | ConcurrencyLimiter max parallel runs globally |
| `:max_queued_runs` | `100` | Max queued runs per SessionServer / RunQueue |

### Circuit Breaker

| Key | Default | Description |
|-----|---------|-------------|
| `:circuit_breaker_failure_threshold` | `5` | Consecutive failures before circuit opens |
| `:circuit_breaker_half_open_max_probes` | `1` | Max probe requests in half-open state |

### SQLite

| Key | Default | Description |
|-----|---------|-------------|
| `:sqlite_max_bind_params` | `32_766` | SQLite bind parameter hard limit per query |
| `:sqlite_busy_retry_attempts` | `25` | Retry attempts for "database is locked" errors |
| `:sqlite_busy_retry_sleep_ms` | `10` | Sleep between busy retries |

### Query Limits

| Key | Default | Description |
|-----|---------|-------------|
| `:max_query_limit` | `1_000` | Absolute max rows per query (EctoQueryAPI) |
| `:default_session_query_limit` | `50` | Default session search result limit |
| `:default_run_query_limit` | `50` | Default run search result limit |
| `:default_event_query_limit` | `100` | Default event search result limit |

### Retention Policy

These defaults are used by `RetentionPolicy.new/0`. Per-policy overrides are still supported by passing keyword options to `RetentionPolicy.new/1`.

| Key | Default | Description |
|-----|---------|-------------|
| `:retention_max_completed_age_days` | `90` | Days before completed sessions are pruned |
| `:retention_hard_delete_after_days` | `30` | Days before hard delete |
| `:retention_batch_size` | `100` | Batch size for prune operations |
| `:retention_exempt_statuses` | `[:active, :paused]` | Statuses exempt from pruning |
| `:retention_exempt_tags` | `["pinned"]` | Tags that exempt sessions from pruning |
| `:retention_prune_event_types_first` | `[:message_streamed, :token_usage_updated]` | Event types pruned first |

### Cost

| Key | Default | Description |
|-----|---------|-------------|
| `:chars_per_token` | `4` | Approximate characters per token for estimation |

PubSub integration is configured per use via sink/callback options (`prefix`, `scope`, `message_wrapper`), not via `AgentSessionManager.Config` keys.

### Shell Adapter

| Key | Default | Description |
|-----|---------|-------------|
| `:default_shell` | `"/bin/sh"` | Default shell binary |
| `:default_success_exit_codes` | `[0]` | Exit codes considered success |

### Workspace

| Key | Default | Description |
|-----|---------|-------------|
| `:excluded_workspace_roots` | `[".git", "deps", "_build", "node_modules"]` | Directories excluded from workspace hashing |

### Routing

| Key | Default | Description |
|-----|---------|-------------|
| `:default_router_name` | `"router"` | Default ProviderRouter instance name |

## Environment-Specific Configuration

```elixir
# config/dev.exs - relaxed timeouts for development
config :agent_session_manager,
  command_timeout_ms: 120_000,
  await_run_timeout_ms: 300_000

# config/test.exs - fast timeouts for testing
config :agent_session_manager,
  command_timeout_ms: 5_000,
  await_run_timeout_ms: 10_000,
  event_stream_poll_interval_ms: 10

# config/prod.exs - tuned for production
config :agent_session_manager,
  max_parallel_sessions: 500,
  max_parallel_runs: 200,
  max_queued_runs: 1_000,
  event_buffer_size: 10_000,
  sqlite_busy_retry_attempts: 50,
  retention_max_completed_age_days: 365
```

## Programmatic Access

```elixir
# Get the built-in default (ignores overrides)
AgentSessionManager.Config.default(:command_timeout_ms)
#=> 30_000

# Get the resolved value (checks process → app env → default)
AgentSessionManager.Config.get(:command_timeout_ms)
#=> 30_000

# List all valid configuration keys
AgentSessionManager.Config.valid_keys()
#=> [:telemetry_enabled, :audit_logging_enabled, :stream_idle_timeout_ms, ...]
```

## Related Guides

- [Configuration](configuration.md) - Feature flags and process-local overrides
- [Model Configuration](model_configuration.md) - Model names and pricing tables
