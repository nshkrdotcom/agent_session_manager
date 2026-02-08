# Session Server Runtime (Feature 6)

`AgentSessionManager.SessionManager` is intentionally functional and stateless between calls. For applications that need **per-session runtime state** (queueing, subscriptions, optional limiter integration), use the opt-in `AgentSessionManager.Runtime.SessionServer`.

## When to Use `SessionServer` vs `SessionManager`

- Use **`SessionManager`** when your application already manages ordering/concurrency and you want a pure orchestration API.
- Use **`SessionServer`** when you want:
  - strict per-session serialization (FIFO run queue)
  - `submit_run/3` + `await_run/3` semantics
  - store-backed subscriptions (`{:session_event, session_id, event}`)
  - optional `ConcurrencyLimiter` acquire/release around execution

## MVP Constraint: Strict Sequential Only

Feature 6 MVP is **strict single-active-run execution**:

- `max_concurrent_runs` is fixed to `1`
- values greater than `1` must fail validation

This guarantees no overlapping `SessionManager.execute_run/4` calls within a single session runtime.

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

## Cancelling Runs

- If the run is **queued**, cancellation is handled locally (no provider call) and the run is marked `:cancelled` in the store with a `:run_cancelled` event.
- If the run is **active**, the server delegates to `SessionManager.cancel_run/3`.

```elixir
:ok = SessionServer.cancel_run(server, run_id)
```

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

