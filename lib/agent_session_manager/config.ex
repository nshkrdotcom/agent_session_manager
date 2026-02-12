defmodule AgentSessionManager.Config do
  @moduledoc """
  Centralized configuration with process-local overrides.

  Every operational default in AgentSessionManager — timeouts, buffer sizes,
  concurrency limits, query limits, and more — is defined here as a single
  source of truth. Individual modules reference `get/1` instead of
  scattering `@default_*` module attributes.

  ## Resolution Order

  When you call `get/1`, the value is resolved as follows:

  1. **Process-local override** — set via `put/2`, scoped to the calling process.
     Automatically cleaned up when the process exits.
  2. **Application environment** — set via `config :agent_session_manager, key: value`
     or `Application.put_env/3`.
  3. **Built-in default** — hardcoded fallback per key.

  This layering follows the same pattern as Elixir's `Logger` module for per-process
  log levels. It enables fully concurrent (`async: true`) testing because each test
  process can override configuration without affecting any other process.

  ## Application Config Example

      # config/config.exs
      config :agent_session_manager,
        command_timeout_ms: 60_000,
        max_parallel_sessions: 200

  See the [Configuration Reference guide](configuration_reference.md) for the
  full list of keys, types, and defaults.

  ## Supported Keys

  ### Feature Flags

  | Key                      | Type      | Default | Used By       |
  |--------------------------|-----------|---------|---------------|
  | `:telemetry_enabled`     | `boolean` | `true`  | `Telemetry`   |
  | `:audit_logging_enabled` | `boolean` | `true`  | `AuditLogger` |
  | `:redaction_enabled`     | `boolean` | `false` | `EventBuilder` |

  ### Redaction

  | Key                       | Type                              | Default        | Used By       |
  |---------------------------|-----------------------------------|----------------|---------------|
  | `:redaction_patterns`     | `:default \| list`                | `:default`     | `EventBuilder` |
  | `:redaction_replacement`  | `String.t() \| :categorized`      | `"[REDACTED]"` | `EventBuilder` |
  | `:redaction_deep_scan`    | `boolean`                         | `true`         | `EventBuilder` |
  | `:redaction_scan_metadata`| `boolean`                         | `false`        | `EventBuilder` |

  ### Timeouts (milliseconds)

  | Key                              | Default   | Used By                      |
  |----------------------------------|-----------|------------------------------|
  | `:stream_idle_timeout_ms`        | `120_000` | `StreamSession`              |
  | `:task_shutdown_timeout_ms`      | `5_000`   | `StreamSession`              |
  | `:await_run_timeout_ms`          | `60_000`  | `SessionServer`              |
  | `:drain_timeout_buffer_ms`       | `1_000`   | `SessionServer.drain/2`      |
  | `:command_timeout_ms`            | `30_000`  | `Exec`, `ShellAdapter`       |
  | `:execute_timeout_ms`            | `60_000`  | `ProviderAdapter`            |
  | `:execute_grace_timeout_ms`      | `5_000`   | `ProviderAdapter`            |
  | `:circuit_breaker_cooldown_ms`   | `30_000`  | `CircuitBreaker`, `Router`   |
  | `:sticky_session_ttl_ms`         | `300_000` | `ProviderRouter`             |
  | `:event_stream_poll_interval_ms` | `250`     | `SessionManager`             |
  | `:genserver_call_timeout_ms`     | `5_000`   | `ProviderAdapter`, `SessionStore` |

  ### Buffer & Memory Limits

  | Key                  | Default     | Used By                  |
  |----------------------|-------------|--------------------------|
  | `:event_buffer_size` | `1_000`     | `EventStream`            |
  | `:max_output_bytes`  | `1_048_576` | `Exec`, `ShellAdapter`   |
  | `:max_patch_bytes`   | `1_048_576` | `GitBackend`             |

  ### Concurrency

  | Key                      | Default | Used By              |
  |--------------------------|---------|----------------------|
  | `:max_parallel_sessions` | `100`   | `ConcurrencyLimiter` |
  | `:max_parallel_runs`     | `50`    | `ConcurrencyLimiter` |
  | `:max_queued_runs`       | `100`   | `SessionServer`, `RunQueue` |

  ### Circuit Breaker

  | Key                                    | Default  | Used By          |
  |----------------------------------------|----------|------------------|
  | `:circuit_breaker_failure_threshold`    | `5`      | `CircuitBreaker` |
  | `:circuit_breaker_half_open_max_probes` | `1`      | `CircuitBreaker` |

  ### SQLite

  | Key                          | Default  | Used By            |
  |------------------------------|----------|--------------------|
  | `:sqlite_max_bind_params`    | `32_766` | `EctoSessionStore` |
  | `:sqlite_busy_retry_attempts`| `25`     | `EctoSessionStore` |
  | `:sqlite_busy_retry_sleep_ms`| `10`     | `EctoSessionStore` |

  ### Query Limits

  | Key                            | Default | Used By                    |
  |--------------------------------|---------|----------------------------|
  | `:max_query_limit`             | `1_000` | `EctoQueryAPI`             |
  | `:default_session_query_limit` | `50`    | `EctoQueryAPI`, `AshQueryAPI` |
  | `:default_run_query_limit`     | `50`    | `EctoQueryAPI`, `AshQueryAPI` |
  | `:default_event_query_limit`   | `100`   | `EctoQueryAPI`, `AshQueryAPI`, `SessionManager` |

  ### Retention

  | Key                                    | Default                                     |
  |----------------------------------------|-----------------------------------------------|
  | `:retention_max_completed_age_days`     | `90`                                         |
  | `:retention_hard_delete_after_days`     | `30`                                         |
  | `:retention_batch_size`                | `100`                                        |
  | `:retention_exempt_statuses`           | `[:active, :paused]`                         |
  | `:retention_exempt_tags`               | `["pinned"]`                                 |
  | `:retention_prune_event_types_first`   | `[:message_streamed, :token_usage_updated]`  |

  ### Cost

  | Key                | Default | Used By              |
  |--------------------|---------|----------------------|
  | `:chars_per_token`  | `4`     | `TranscriptBuilder` |

  ### Shell Adapter

  | Key                          | Default    | Used By        |
  |------------------------------|------------|----------------|
  | `:default_shell`             | `"/bin/sh"`| `ShellAdapter` |
  | `:default_success_exit_codes`| `[0]`      | `ShellAdapter` |

  ### Workspace

  | Key                        | Default                                    | Used By       |
  |----------------------------|--------------------------------------------|---------------|
  | `:excluded_workspace_roots`| `[".git", "deps", "_build", "node_modules"]`| `HashBackend` |

  ### Routing

  | Key                    | Default    | Used By          |
  |------------------------|------------|------------------|
  | `:default_router_name` | `"router"` | `ProviderRouter` |
  """

  @typedoc "Configuration keys supported by this module."
  @type key ::
          :telemetry_enabled
          | :audit_logging_enabled
          | :redaction_enabled
          | :redaction_patterns
          | :redaction_replacement
          | :redaction_deep_scan
          | :redaction_scan_metadata
          # Timeouts
          | :stream_idle_timeout_ms
          | :task_shutdown_timeout_ms
          | :await_run_timeout_ms
          | :drain_timeout_buffer_ms
          | :command_timeout_ms
          | :execute_timeout_ms
          | :execute_grace_timeout_ms
          | :circuit_breaker_cooldown_ms
          | :sticky_session_ttl_ms
          | :event_stream_poll_interval_ms
          | :genserver_call_timeout_ms
          # Limits
          | :event_buffer_size
          | :max_output_bytes
          | :max_patch_bytes
          | :error_text_max_bytes
          | :error_text_max_lines
          # Concurrency
          | :max_parallel_sessions
          | :max_parallel_runs
          | :max_queued_runs
          # Circuit Breaker
          | :circuit_breaker_failure_threshold
          | :circuit_breaker_half_open_max_probes
          # SQLite
          | :sqlite_max_bind_params
          | :sqlite_busy_retry_attempts
          | :sqlite_busy_retry_sleep_ms
          # Query
          | :max_query_limit
          | :default_session_query_limit
          | :default_run_query_limit
          | :default_event_query_limit
          # Retention
          | :retention_max_completed_age_days
          | :retention_hard_delete_after_days
          | :retention_batch_size
          | :retention_exempt_statuses
          | :retention_exempt_tags
          | :retention_prune_event_types_first
          # Cost
          | :chars_per_token
          # Shell
          | :default_shell
          | :default_success_exit_codes
          # Workspace
          | :excluded_workspace_roots
          # Routing
          | :default_router_name

  @valid_keys [
    # Feature flags
    :telemetry_enabled,
    :audit_logging_enabled,
    :redaction_enabled,
    :redaction_patterns,
    :redaction_replacement,
    :redaction_deep_scan,
    :redaction_scan_metadata,
    # Timeouts
    :stream_idle_timeout_ms,
    :task_shutdown_timeout_ms,
    :await_run_timeout_ms,
    :drain_timeout_buffer_ms,
    :command_timeout_ms,
    :execute_timeout_ms,
    :execute_grace_timeout_ms,
    :circuit_breaker_cooldown_ms,
    :sticky_session_ttl_ms,
    :event_stream_poll_interval_ms,
    :genserver_call_timeout_ms,
    # Limits
    :event_buffer_size,
    :max_output_bytes,
    :max_patch_bytes,
    :error_text_max_bytes,
    :error_text_max_lines,
    # Concurrency
    :max_parallel_sessions,
    :max_parallel_runs,
    :max_queued_runs,
    # Circuit Breaker
    :circuit_breaker_failure_threshold,
    :circuit_breaker_half_open_max_probes,
    # SQLite
    :sqlite_max_bind_params,
    :sqlite_busy_retry_attempts,
    :sqlite_busy_retry_sleep_ms,
    # Query
    :max_query_limit,
    :default_session_query_limit,
    :default_run_query_limit,
    :default_event_query_limit,
    # Retention
    :retention_max_completed_age_days,
    :retention_hard_delete_after_days,
    :retention_batch_size,
    :retention_exempt_statuses,
    :retention_exempt_tags,
    :retention_prune_event_types_first,
    # Cost
    :chars_per_token,
    # Shell
    :default_shell,
    :default_success_exit_codes,
    # Workspace
    :excluded_workspace_roots,
    # Routing
    :default_router_name
  ]

  @doc """
  Returns the list of valid configuration keys.
  """
  @spec valid_keys() :: [key()]
  def valid_keys, do: @valid_keys

  @doc """
  Returns the resolved value for `key`.

  Checks the process dictionary first, then Application environment,
  then falls back to the built-in default.
  """
  @spec get(key()) :: term()
  def get(key) when key in @valid_keys do
    case Process.get({__MODULE__, key}, :__config_not_set__) do
      :__config_not_set__ ->
        Application.get_env(:agent_session_manager, key, default(key))

      value ->
        value
    end
  end

  @doc """
  Sets a process-local override for `key`.

  This override is visible only to the calling process and is automatically
  cleaned up when the process exits. It takes priority over Application
  environment and built-in defaults.
  """
  @spec put(key(), term()) :: :ok
  def put(key, value) when key in @valid_keys do
    Process.put({__MODULE__, key}, value)
    :ok
  end

  @doc """
  Removes the process-local override for `key`.

  After deletion, `get/1` falls back to Application environment or the
  built-in default.
  """
  @spec delete(key()) :: :ok
  def delete(key) when key in @valid_keys do
    Process.delete({__MODULE__, key})
    :ok
  end

  @doc """
  Returns the built-in default for `key`, ignoring process-local and
  application environment overrides.
  """
  @spec default(key()) :: term()
  # Feature flags
  def default(:telemetry_enabled), do: true
  def default(:audit_logging_enabled), do: true
  def default(:redaction_enabled), do: false
  def default(:redaction_patterns), do: :default
  def default(:redaction_replacement), do: "[REDACTED]"
  def default(:redaction_deep_scan), do: true
  def default(:redaction_scan_metadata), do: false
  # Timeouts
  def default(:stream_idle_timeout_ms), do: 120_000
  def default(:task_shutdown_timeout_ms), do: 5_000
  def default(:await_run_timeout_ms), do: 60_000
  def default(:drain_timeout_buffer_ms), do: 1_000
  def default(:command_timeout_ms), do: 30_000
  def default(:execute_timeout_ms), do: 60_000
  def default(:execute_grace_timeout_ms), do: 5_000
  def default(:circuit_breaker_cooldown_ms), do: 30_000
  def default(:sticky_session_ttl_ms), do: 300_000
  def default(:event_stream_poll_interval_ms), do: 250
  def default(:genserver_call_timeout_ms), do: 5_000
  # Limits
  def default(:event_buffer_size), do: 1_000
  def default(:max_output_bytes), do: 1_048_576
  def default(:max_patch_bytes), do: 1_048_576
  def default(:error_text_max_bytes), do: 16_384
  def default(:error_text_max_lines), do: 200
  # Concurrency
  def default(:max_parallel_sessions), do: 100
  def default(:max_parallel_runs), do: 50
  def default(:max_queued_runs), do: 100
  # Circuit Breaker
  def default(:circuit_breaker_failure_threshold), do: 5
  def default(:circuit_breaker_half_open_max_probes), do: 1
  # SQLite
  def default(:sqlite_max_bind_params), do: 32_766
  def default(:sqlite_busy_retry_attempts), do: 25
  def default(:sqlite_busy_retry_sleep_ms), do: 10
  # Query
  def default(:max_query_limit), do: 1_000
  def default(:default_session_query_limit), do: 50
  def default(:default_run_query_limit), do: 50
  def default(:default_event_query_limit), do: 100
  # Retention
  def default(:retention_max_completed_age_days), do: 90
  def default(:retention_hard_delete_after_days), do: 30
  def default(:retention_batch_size), do: 100
  def default(:retention_exempt_statuses), do: [:active, :paused]
  def default(:retention_exempt_tags), do: ["pinned"]
  def default(:retention_prune_event_types_first), do: [:message_streamed, :token_usage_updated]
  # Cost
  def default(:chars_per_token), do: 4
  # Shell
  def default(:default_shell), do: "/bin/sh"
  def default(:default_success_exit_codes), do: [0]
  # Workspace
  def default(:excluded_workspace_roots), do: [".git", "deps", "_build", "node_modules"]
  # Routing
  def default(:default_router_name), do: "router"
end
