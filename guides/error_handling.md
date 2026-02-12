# Error Handling

AgentSessionManager uses a structured error taxonomy where every error has a machine-readable code, human-readable message, and optional details. All operations return tagged tuples (`{:ok, result}` or `{:error, %Error{}}`).

## The Error Struct

```elixir
alias AgentSessionManager.Core.Error

error = Error.new(:validation_error, "agent_id is required")

error.code       # => :validation_error
error.message    # => "agent_id is required"
error.details    # => %{}
error.context    # => %{}
error.timestamp  # => ~U[2025-01-27 12:00:00Z]
```

### Creating Errors

```elixir
# Basic
error = Error.new(:session_not_found, "Session not found: ses_abc")

# With details and context
error = Error.new(:provider_rate_limited, "Rate limit exceeded",
  details: %{status_code: 429, retry_after: 30, body: "Too many requests"},
  provider_error: %{
    provider: :claude,
    kind: :rate_limit,
    message: "Rate limit exceeded",
    exit_code: nil,
    stderr: nil,
    truncated?: nil
  },
  context: %{operation: "execute_run"}
)

# With default message
error = Error.new(:timeout)
error.message  # => "Operation timed out"
```

### `provider_error` Contract

Use `Error.provider_error` for cross-provider transport/CLI diagnostics and keep
provider-specific extras in `Error.details`.

```elixir
%{
  provider: :codex | :amp | :claude | :gemini | :unknown,
  kind: atom(),
  message: String.t(),
  exit_code: integer() | nil,
  stderr: String.t() | nil,
  truncated?: boolean() | nil
}
```

`stderr` is normalized, truncated, and then emitted/persisted. Truncation
limits come from `AgentSessionManager.Config` (`:error_text_max_bytes`,
`:error_text_max_lines`).

### Wrapping Exceptions

```elixir
try do
  raise "something broke"
rescue
  e ->
    error = Error.wrap(:internal_error, e)
    error.message  # => "something broke"
    error.details  # => %{original_exception: RuntimeError}
end
```

### Raising Errors

`Error` implements the `Exception` behaviour, so you can raise it:

```elixir
raise Error, code: :validation_error, message: "Invalid input"
```

## Error Categories

Every error code belongs to a category:

### Validation Errors
| Code | Default Message |
|------|----------------|
| `:validation_error` | Validation error occurred |
| `:invalid_input` | Invalid input provided |
| `:missing_required_field` | Required field is missing |
| `:invalid_format` | Invalid format |

### State Errors
| Code | Default Message |
|------|----------------|
| `:invalid_status` | Invalid status value |
| `:invalid_transition` | Invalid state transition |
| `:invalid_event_type` | Invalid event type |
| `:invalid_capability_type` | Invalid capability type |
| `:missing_required_capability` | Required capability is missing |

### Resource Errors
| Code | Default Message |
|------|----------------|
| `:not_found` | Resource not found |
| `:session_not_found` | Session not found |
| `:run_not_found` | Run not found |
| `:capability_not_found` | Capability not found |
| `:already_exists` | Resource already exists |
| `:duplicate_capability` | Capability with this name already exists |

### Provider Errors
| Code | Default Message |
|------|----------------|
| `:provider_error` | Provider error occurred |
| `:provider_unavailable` | Provider is unavailable |
| `:provider_rate_limited` | Provider rate limit exceeded |
| `:provider_timeout` | Provider request timed out |
| `:provider_authentication_failed` | Provider authentication failed |
| `:provider_quota_exceeded` | Provider quota exceeded |

### Storage Errors
| Code | Default Message |
|------|----------------|
| `:storage_error` | Storage error occurred |
| `:storage_connection_failed` | Storage connection failed |
| `:storage_write_failed` | Storage write operation failed |
| `:storage_read_failed` | Storage read operation failed |

### Runtime Errors
| Code | Default Message |
|------|----------------|
| `:timeout` | Operation timed out |
| `:cancelled` | Operation was cancelled |
| `:internal_error` | Internal error occurred |
| `:unknown_error` | An unknown error occurred |

### Concurrency Errors
| Code | Default Message |
|------|----------------|
| `:max_sessions_exceeded` | Maximum parallel sessions limit exceeded |
| `:max_runs_exceeded` | Maximum parallel runs limit exceeded |
| `:capability_not_supported` | Capability not supported by provider |
| `:invalid_operation` | Operation not valid for current state |

### Tool Errors
| Code | Default Message |
|------|----------------|
| `:tool_error` | Tool error occurred |
| `:tool_not_found` | Tool not found |
| `:tool_execution_failed` | Tool execution failed |
| `:tool_permission_denied` | Tool permission denied |

## Retryable Errors

Some errors are transient and worth retrying. Check with `Error.retryable?/1`:

```elixir
Error.retryable?(:provider_timeout)       # => true
Error.retryable?(:provider_rate_limited)   # => true
Error.retryable?(:provider_unavailable)    # => true
Error.retryable?(:storage_connection_failed) # => true
Error.retryable?(:timeout)                 # => true

Error.retryable?(:validation_error)        # => false
Error.retryable?(:session_not_found)       # => false
```

You can also pass an Error struct:

```elixir
Error.retryable?(error)  # checks error.code
```

## Working with Error Categories

```elixir
Error.category(:provider_timeout)    # => :provider
Error.category(:session_not_found)   # => :resource
Error.category(:validation_error)    # => :validation
Error.category(:max_runs_exceeded)   # => :concurrency

# Get all codes in a category
Error.provider_codes()     # => [:provider_error, :provider_unavailable, ...]
Error.validation_codes()   # => [:validation_error, :invalid_input, ...]
Error.resource_codes()     # => [:not_found, :session_not_found, ...]
Error.concurrency_codes()  # => [:max_sessions_exceeded, ...]
Error.tool_codes()         # => [:tool_error, :tool_not_found, ...]
```

## Pattern Matching on Errors

```elixir
case SessionManager.execute_run(store, adapter, run_id) do
  {:ok, result} ->
    handle_success(result)

  {:error, %Error{code: :provider_rate_limited} = error} ->
    # Retry with backoff
    Process.sleep(error.details[:retry_after] * 1000)
    retry(run_id)

  {:error, %Error{code: :provider_timeout}} ->
    # Retry immediately
    retry(run_id)

  {:error, %Error{code: code}} when code in [:session_not_found, :run_not_found] ->
    # Resource not found -- nothing to retry
    {:error, :not_found}

  {:error, %Error{} = error} ->
    Logger.error("Run failed: #{error}")
    {:error, error}
end
```

## Serialization

Errors can be serialized and reconstructed:

```elixir
map = Error.to_map(error)
# => %{
#   "code" => "provider_timeout",
#   "message" => "Provider request timed out",
#   "details" => %{},
#   "provider_error" => nil,
#   "timestamp" => "2025-01-27T12:00:00Z",
#   ...
# }

{:ok, restored} = Error.from_map(map)
```

## String Representation

Errors implement `String.Chars`:

```elixir
"#{error}"  # => "[provider_timeout] Provider request timed out"
```
