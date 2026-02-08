# Concurrency

AgentSessionManager provides two concurrency mechanisms: a **ConcurrencyLimiter** for enforcing maximum parallel sessions and runs, and **ControlOperations** for interrupting, cancelling, pausing, and resuming runs.

## ConcurrencyLimiter

The limiter tracks active sessions and runs, enforcing configurable maximums.

### Starting the Limiter

```elixir
alias AgentSessionManager.Concurrency.ConcurrencyLimiter

{:ok, limiter} = ConcurrencyLimiter.start_link(
  max_parallel_sessions: 10,   # default: 100
  max_parallel_runs: 20        # default: 50
)
```

Use `:infinity` for either limit to disable enforcement:

```elixir
{:ok, limiter} = ConcurrencyLimiter.start_link(
  max_parallel_sessions: :infinity,
  max_parallel_runs: :infinity
)
```

### Acquiring and Releasing Slots

Before starting a session or run, acquire a slot. When done, release it.

```elixir
# Acquire a session slot
:ok = ConcurrencyLimiter.acquire_session_slot(limiter, session.id)

# Acquire a run slot (associated with a session)
:ok = ConcurrencyLimiter.acquire_run_slot(limiter, session.id, run.id)

# ... execute the run ...

# Release when done
:ok = ConcurrencyLimiter.release_run_slot(limiter, run.id)
:ok = ConcurrencyLimiter.release_session_slot(limiter, session.id)
```

When the limit is reached, acquire returns an error:

```elixir
{:error, %Error{code: :max_sessions_exceeded}} =
  ConcurrencyLimiter.acquire_session_slot(limiter, "one-too-many")

{:error, %Error{code: :max_runs_exceeded}} =
  ConcurrencyLimiter.acquire_run_slot(limiter, session_id, "one-too-many")
```

### Idempotency

All operations are idempotent:
- Acquiring the same session/run ID multiple times counts as one slot
- Releasing a non-existent session/run is a no-op

### Session Cleanup

Releasing a session automatically releases all its associated runs:

```elixir
:ok = ConcurrencyLimiter.acquire_session_slot(limiter, "ses_1")
:ok = ConcurrencyLimiter.acquire_run_slot(limiter, "ses_1", "run_1")
:ok = ConcurrencyLimiter.acquire_run_slot(limiter, "ses_1", "run_2")

# Releasing the session releases both runs
:ok = ConcurrencyLimiter.release_session_slot(limiter, "ses_1")
```

### Checking Status

```elixir
status = ConcurrencyLimiter.get_status(limiter)
# => %{
#   active_sessions: 3,
#   active_runs: 7,
#   max_parallel_sessions: 10,
#   max_parallel_runs: 20,
#   available_session_slots: 7,
#   available_run_slots: 13
# }

limits = ConcurrencyLimiter.get_limits(limiter)
# => %{max_parallel_sessions: 10, max_parallel_runs: 20}
```

## ControlOperations

The `ControlOperations` module provides a centralized way to manage run lifecycle control operations.

### Starting ControlOperations

```elixir
alias AgentSessionManager.Concurrency.ControlOperations

{:ok, ops} = ControlOperations.start_link(adapter: adapter)
```

### Available Operations

**Interrupt** -- immediately stop a running operation:
```elixir
{:ok, run_id} = ControlOperations.interrupt(ops, run_id)
```
`interrupt/2` uses the provider `cancel/2` contract under the hood, so adapters only need to implement `cancel/2`.

**Cancel** -- permanently cancel an operation (terminal state):
```elixir
{:ok, run_id} = ControlOperations.cancel(ops, run_id)
```

**Pause** -- temporarily suspend an operation (requires adapter support):
```elixir
{:ok, run_id} = ControlOperations.pause(ops, run_id)
```

**Resume** -- resume a paused operation (requires adapter support):
```elixir
{:ok, run_id} = ControlOperations.resume(ops, run_id)
```

### Idempotency

All control operations are idempotent:
- Interrupting an already interrupted run succeeds
- Cancelling an already cancelled run succeeds
- Pausing an already paused run succeeds
- Resuming an already running run succeeds

### Terminal States

Once a run enters a terminal state (`:cancelled`, `:completed`, `:failed`, `:timeout`), it cannot be resumed:

```elixir
# This will fail
{:error, %Error{code: :invalid_operation}} = ControlOperations.resume(ops, cancelled_run_id)

# Check if a state is terminal
ControlOperations.terminal_state?(:cancelled)  # => true
ControlOperations.terminal_state?(:running)    # => false
```

### Capability Requirements

Pause and resume require the adapter to support these capabilities. If the adapter doesn't have them:

```elixir
{:error, %Error{code: :capability_not_supported}} = ControlOperations.pause(ops, run_id)
```

### Batch Operations

```elixir
# Cancel multiple runs at once
results = ControlOperations.cancel_all(ops, [run_id_1, run_id_2, run_id_3])
# => %{"run_1" => :ok, "run_2" => :ok, "run_3" => {:error, ...}}

# Interrupt all runs in a session
results = ControlOperations.interrupt_session(ops, session_id)
```

For session-level operations, runs must be registered first:

```elixir
:ok = ControlOperations.register_run(ops, session_id, run_id)
```

### Operation History

Every control operation is recorded:

```elixir
status = ControlOperations.get_operation_status(ops, run_id)
# => %{
#   last_operation: :cancel,
#   state: :cancelled,
#   history: [
#     %{operation: :interrupt, timestamp: ~U[...], result: :ok},
#     %{operation: :cancel, timestamp: ~U[...], result: :ok}
#   ]
# }

history = ControlOperations.get_operation_history(ops, run_id)
# => [%{operation: :interrupt, ...}, %{operation: :cancel, ...}]
```

## Runtime Integration (Feature 6)

When using `AgentSessionManager.Runtime.SessionServer`, you can pass a limiter via `limiter:`. The runtime will:

- acquire a run slot before starting execution
- release the run slot after completion or cancellation

This makes limiter enforcement a single configuration point for queued session runtimes.
