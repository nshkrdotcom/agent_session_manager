# Custom Persistence Guide

This guide explains how to implement custom persistence adapters for
AgentSessionManager.

Core ports:

- `SessionStore` for session/run/event persistence
- `ArtifactStore` for binary artifact storage
- `QueryAPI` for cross-session read/query operations
- `Maintenance` for retention and integrity workflows

## SessionStore

`AgentSessionManager.Ports.SessionStore` is the primary persistence contract.

Callback groups:

- Session callbacks: `save_session/2`, `get_session/2`, `list_sessions/2`, `delete_session/2`
- Run callbacks: `save_run/2`, `get_run/2`, `list_runs/3`, `get_active_run/2`
- Event callbacks: `append_event/2`, `append_event_with_sequence/2`,
  `append_events/2`, `get_events/3`, `get_latest_sequence/2`
- Atomic lifecycle callback: `flush/2`

### Semantics your adapter should guarantee

- Idempotent writes for duplicate IDs
- Append-only event behavior
- Atomic, monotonic per-session sequence assignment
- Consistent error tuples using `AgentSessionManager.Core.Error`

## ArtifactStore

`AgentSessionManager.Ports.ArtifactStore` is a simple binary contract:

- `put/4`
- `get/3`
- `delete/3`

Keys should be treated as immutable identifiers from the application boundary.

## QueryAPI and Maintenance

For SQL-backed stacks, query and maintenance are separate module adapters. They
accept an explicit context (usually Repo) via tuple refs at call sites:

```elixir
query_ref = {MyApp.QueryAdapter, query_context}
maint_ref = {MyApp.MaintenanceAdapter, maintenance_context}
```

This keeps read/reporting and maintenance operations independent from the
SessionStore process lifecycle.

## Recommended implementation pattern

Most custom stores use GenServer for write serialization and simple lifecycle
management.

```elixir
defmodule MyApp.CustomSessionStore do
  use GenServer

  @behaviour AgentSessionManager.Ports.SessionStore

  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl SessionStore
  def save_session(store, %Session{} = session),
    do: GenServer.call(store, {:save_session, session})

  @impl SessionStore
  def append_events(store, events),
    do: GenServer.call(store, {:append_events, events})

  @impl SessionStore
  def flush(store, execution_result),
    do: GenServer.call(store, {:flush, execution_result})

  # Implement remaining callbacks similarly...
end
```

## Atomic sequencing and flush

### `append_event_with_sequence/2` and `append_events/2`

Use one atomic unit (transaction or lock) to:

1. Read/update per-session sequence counter
2. Insert event rows
3. Return persisted events with assigned `sequence_number`

### `flush/2`

`flush/2` should atomically persist:

- session
- run
- events
- provider metadata (if your backend stores it)

If any part fails, no partial write should remain in persistent state.

## Error handling

Return `AgentSessionManager.Core.Error` for all failures.

```elixir
alias AgentSessionManager.Core.Error

{:error, Error.new(:session_not_found, "Session not found: #{session_id}")}
{:error, Error.new(:run_not_found, "Run not found: #{run_id}")}
{:error, Error.new(:storage_error, "Write failed: #{inspect(reason)}")}
```

## Testing strategy

Run contract-style tests against your adapter and include concurrency checks for:

- duplicate event IDs
- concurrent appends
- sequence monotonicity
- `flush/2` rollback behavior

When possible, verify behavior through `SessionStore` port calls instead of
adapter-internal functions.
