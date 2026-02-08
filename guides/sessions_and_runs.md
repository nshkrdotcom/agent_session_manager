# Sessions and Runs

Sessions and runs are the two main lifecycle containers in AgentSessionManager. A **session** groups related interactions with an agent, and a **run** represents a single execution within that session.

## Session Lifecycle

Sessions follow this state machine:

```
pending ──> active ──> completed
                   ──> failed
                   ──> cancelled
            paused ──> active (resumed)
```

### Creating a Session

```elixir
alias AgentSessionManager.Core.Session

{:ok, session} = Session.new(%{
  agent_id: "research-agent",               # required -- identifies the agent type
  context: %{system_prompt: "Be concise."}, # optional -- shared context for all runs
  metadata: %{user_id: "u-123"},            # optional -- arbitrary metadata
  tags: ["research", "v2"]                  # optional -- for filtering
})

session.status   # => :pending
session.id       # => "ses_a1b2c3d4..."
```

The `agent_id` identifies what kind of agent this session is for. The `context` map carries data shared across all runs in the session (system prompts, configuration). The `metadata` map is for your application's own data.

### Session State Transitions

```elixir
# Activate a pending session
{:ok, active} = Session.update_status(session, :active)

# Pause an active session
{:ok, paused} = Session.update_status(active, :paused)

# Resume a paused session
{:ok, resumed} = Session.update_status(paused, :active)

# Complete a session
{:ok, completed} = Session.update_status(active, :completed)
```

Invalid transitions return error tuples:

```elixir
{:error, %Error{code: :invalid_status}} = Session.update_status(session, :not_a_status)
```

### Via SessionManager

When using `SessionManager`, session transitions also persist to the store and emit events:

```elixir
# Creates session, saves to store, emits :session_created event
{:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "my-agent"})

# Updates status, saves, emits :session_started event
{:ok, session} = SessionManager.activate_session(store, session.id)

# Updates status, saves, emits :session_completed event
{:ok, session} = SessionManager.complete_session(store, session.id)

# Marks failed with error context
{:ok, session} = SessionManager.fail_session(store, session.id, error)
```

Persisted lifecycle events receive durable `sequence_number` assignment from the store at append time, enabling cursor-based replay with `SessionStore.get_events/3`.

### Hierarchical Sessions

Sessions can reference a parent session for hierarchical agent workflows:

```elixir
{:ok, parent} = Session.new(%{agent_id: "orchestrator"})

{:ok, child} = Session.new(%{
  agent_id: "worker",
  parent_session_id: parent.id
})
```

## Run Lifecycle

Runs follow this state machine:

```
pending ──> running ──> completed
                    ──> failed
                    ──> cancelled
                    ──> timeout
```

### Creating a Run

```elixir
alias AgentSessionManager.Core.Run

{:ok, run} = Run.new(%{
  session_id: session.id,                    # required -- parent session
  input: %{messages: [%{role: "user", content: "Hello"}]},  # optional -- input data
  metadata: %{request_id: "req-789"}         # optional -- arbitrary metadata
})

run.status      # => :pending
run.turn_count  # => 0
run.token_usage # => %{}
```

### Run State Transitions

```elixir
# Start execution
{:ok, running} = Run.update_status(run, :running)

# Complete with output
{:ok, completed} = Run.set_output(running, %{content: "Hello!", stop_reason: "end_turn"})
completed.status    # => :completed
completed.ended_at  # => %DateTime{...}

# Or fail with error
{:ok, failed} = Run.set_error(running, %{code: :provider_timeout, message: "Timed out"})
failed.status  # => :failed
```

Terminal statuses (`:completed`, `:failed`, `:cancelled`, `:timeout`) automatically set the `ended_at` timestamp.

### Token Usage Tracking

Token usage accumulates across updates:

```elixir
{:ok, run} = Run.update_token_usage(run, %{input_tokens: 100, output_tokens: 50})
{:ok, run} = Run.update_token_usage(run, %{input_tokens: 20, output_tokens: 30})

run.token_usage
# => %{input_tokens: 120, output_tokens: 80}
```

### Turn Counting

```elixir
{:ok, run} = Run.increment_turn(run)
{:ok, run} = Run.increment_turn(run)
run.turn_count  # => 2
```

### Via SessionManager

```elixir
# Creates run, saves, checks capabilities
{:ok, run} = SessionManager.start_run(store, adapter, session.id, input)

# Executes via adapter, persists events and result
{:ok, result} = SessionManager.execute_run(store, adapter, run.id)

# Cancels via adapter, updates status
{:ok, _} = SessionManager.cancel_run(store, adapter, run.id)
```

Feature options are available through the same `execute_run/4` API:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: true,
  continuation_opts: [max_messages: 100],
  adapter_opts: [timeout: 120_000],
  workspace: [
    enabled: true,
    path: File.cwd!(),
    strategy: :auto,
    capture_patch: true,
    max_patch_bytes: 1_048_576,
    rollback_on_failure: false
  ]
)
```

## Querying Sessions and Runs

The `SessionStore` port supports filtering:

```elixir
alias AgentSessionManager.Ports.SessionStore

# List all sessions
{:ok, sessions} = SessionStore.list_sessions(store)

# Filter by status
{:ok, active} = SessionStore.list_sessions(store, status: :active)

# Filter by agent
{:ok, agent_sessions} = SessionStore.list_sessions(store, agent_id: "my-agent")

# List runs for a session
{:ok, runs} = SessionStore.list_runs(store, session.id)
{:ok, completed_runs} = SessionStore.list_runs(store, session.id, status: :completed)

# Get the currently running run
{:ok, active_run} = SessionStore.get_active_run(store, session.id)
# => {:ok, %Run{status: :running, ...}} or {:ok, nil}
```

## Serialization

Both sessions and runs can be serialized to maps (for JSON, database storage, etc.) and reconstructed:

```elixir
# Serialize
map = Session.to_map(session)
# => %{"id" => "ses_...", "agent_id" => "my-agent", "status" => "pending", ...}

# Reconstruct
{:ok, restored} = Session.from_map(map)

# Same for runs
run_map = Run.to_map(run)
{:ok, restored_run} = Run.from_map(run_map)
```

## Provider Metadata

When runs execute through `SessionManager`, provider-specific metadata is automatically merged into the run and session metadata. This includes the provider name, provider session ID, and model used:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id)
{:ok, updated_run} = SessionStore.get_run(store, run.id)

updated_run.metadata
# => %{provider: "claude", provider_session_id: "sess_...", model: "claude-haiku-4-5-..."}
```
