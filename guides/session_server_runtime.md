# Session Server Runtime (Feature 6)

`AgentSessionManager.SessionManager` is intentionally functional and stateless between calls. For applications that need **per-session runtime state** (queueing, subscriptions, optional limiter integration), use the opt-in `AgentSessionManager.Runtime.SessionServer`.

## When to Use `SessionServer` vs `SessionManager`

- Use **`SessionManager`** when your application already manages ordering/concurrency and you want a pure orchestration API.
- Use **`SessionServer`** when you want:
  - per-session run queueing (FIFO) with configurable concurrency
  - `submit_run/3` + `await_run/3` semantics
  - store-backed subscriptions (`{:session_event, session_id, event}`)
  - optional `ConcurrencyLimiter` acquire/release around execution
  - optional `ControlOperations` integration for interrupt/cancel
  - operational APIs (`drain/2`, `status/1`)

## Concurrency Modes

### Sequential (max_concurrent_runs: 1)

Only one run executes at a time. Submitted runs queue in FIFO order and
execute one after another. This is the safest mode and the default.

### Multi-Slot (max_concurrent_runs > 1) -- Phase 2

Multiple runs execute in parallel within a single session, bounded by
the configured slot count. Runs never exceed `max_concurrent_runs`.

```elixir
{:ok, server} =
  SessionServer.start_link(
    store: store,
    adapter: adapter,
    session_opts: %{agent_id: "my-session"},
    max_concurrent_runs: 3,
    max_queued_runs: 100
  )
```

When all slots are in use, additional runs queue and start as slots free up.
Per-run event callbacks include `run_id` so subscribers can disambiguate
interleaved runs.

## Starting a Session Server

You can start a server directly:

```elixir
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}
alias AgentSessionManager.Runtime.SessionServer

{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link(model: "claude-haiku-4-5-20251001", tools: [])

{:ok, server} =
  SessionServer.start_link(
    store: store,
    adapter: adapter,
    session_opts: %{
      agent_id: "my-session",
      context: %{system_prompt: "Be concise."}
    },
    max_concurrent_runs: 1,
    max_queued_runs: 100
  )
```

`SessionServer` supports bootstrapping from:

- `:session_opts` (creates + activates a session), or
- `:session_id` (attaches to an existing persisted session)

### Options

| Option | Default | Description |
|---|---|---|
| `:store` | required | `SessionStore` process |
| `:adapter` | required | `ProviderAdapter` or `ProviderRouter` process |
| `:session_opts` | -- | Map of attrs for session creation |
| `:session_id` | -- | ID of existing persisted session |
| `:max_concurrent_runs` | `1` | Max in-flight runs (positive integer) |
| `:max_queued_runs` | `100` | Max queue depth |
| `:limiter` | `nil` | Optional `ConcurrencyLimiter` process |
| `:control_ops` | `nil` | Optional `ControlOperations` process |
| `:default_execute_opts` | `[]` | Default options merged into each run |

## Submitting and Awaiting Runs

`submit_run/3` enqueues a run (FIFO) and returns its `run_id`:

```elixir
{:ok, run_id} =
  SessionServer.submit_run(server, %{
    messages: [%{role: "user", content: "Hello"}]
  })

{:ok, result} = SessionServer.await_run(server, run_id, 120_000)
```

`execute_run/3` is a convenience that submits then awaits:

```elixir
{:ok, result} =
  SessionServer.execute_run(server, %{
    messages: [%{role: "user", content: "Hello"}]
  }, timeout: 120_000)
```

## Cancelling and Interrupting Runs

- If the run is **queued**, cancellation is handled locally (no provider call) and the run is marked `:cancelled` in the store with a `:run_cancelled` event.
- If the run is **in-flight**, the server delegates to `SessionManager.cancel_run/3`.

```elixir
:ok = SessionServer.cancel_run(server, run_id)
```

When `ControlOperations` is configured, `interrupt_run/2` delegates to
the control operations manager:

```elixir
{:ok, ^run_id} = SessionServer.interrupt_run(server, run_id)
```

## Operational APIs

### Status

```elixir
status = SessionServer.status(server)
# %{
#   session_id: "ses_...",
#   in_flight_count: 2,
#   in_flight_runs: ["run_a", "run_b"],
#   queued_count: 3,
#   queued_runs: ["run_c", "run_d", "run_e"],
#   max_concurrent_runs: 3,
#   max_queued_runs: 100,
#   subscribers: 1
# }
```

### Drain

`drain/2` waits for all in-flight and queued runs to complete:

```elixir
:ok = SessionServer.drain(server, 30_000)
```

Returns `{:error, :timeout}` if the timeout elapses before all work finishes.

## Using `SessionSupervisor` (Optional)

For applications that want a standard runtime process tree:

```elixir
alias AgentSessionManager.Runtime.SessionSupervisor

{:ok, sup} = SessionSupervisor.start_link(name: MyApp.SessionRuntime)

{:ok, pid} =
  SessionSupervisor.start_session(MyApp.SessionRuntime,
    session_id: session.id,
    store: store,
    adapter: adapter
  )
```

Use `SessionSupervisor.whereis/2` to look up a session server by `session_id`.
