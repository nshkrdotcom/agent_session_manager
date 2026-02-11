# Getting Started

This guide walks you through installing AgentSessionManager, running your first session, and understanding the core workflow.

## Installation

Add `agent_session_manager` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"}
  ]
end
```

Fetch dependencies:

```bash
mix deps.get
```

AgentSessionManager pulls in a small set of runtime dependencies:

- `telemetry` -- for observability hooks
- `jason` -- for JSON encoding/decoding

Provider SDK dependencies are optional and only needed when you use the matching adapter:

- `claude_agent_sdk` -- required for `ClaudeAdapter`
- `codex_sdk` -- required for `CodexAdapter`
- `amp_sdk` -- required for `AmpAdapter`

If you are running a persistence-only stack, add only `agent_session_manager` plus your chosen persistence deps (for example `ecto_sql` + `ecto_sqlite3`).

## Quick One-Shot Usage

For simple request/response workflows, `run_once/4` handles the entire lifecycle in one call:

```elixir
alias AgentSessionManager.SessionManager
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}

{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))

{:ok, result} = SessionManager.run_once(store, adapter, %{
  messages: [%{role: "user", content: "What is Elixir?"}]
},
  context: %{system_prompt: "You are a helpful assistant."},
  event_callback: fn event -> IO.write(event.data[:delta] || "") end
)

IO.puts(result.output.content)
IO.inspect(result.token_usage)
# result also includes :session_id, :run_id, and :events
```

This creates a session, activates it, starts a run, executes it, and completes the session. On error, the session is automatically marked as failed.

## Your First Session (Full Lifecycle)

The fundamental workflow is: **create a session, create a run inside it, execute the run, inspect the result.**

```elixir
alias AgentSessionManager.Core.{Session, Run}
alias AgentSessionManager.SessionManager
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}

# Start infrastructure processes
{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))

# Create a session (status: :pending)
{:ok, session} = SessionManager.start_session(store, adapter, %{
  agent_id: "my-agent",
  context: %{system_prompt: "You are a helpful assistant."},
  metadata: %{user_id: "user-42"}
})

# Activate the session (status: :active)
{:ok, session} = SessionManager.activate_session(store, session.id)

# Create a run with input
{:ok, run} = SessionManager.start_run(store, adapter, session.id, %{
  messages: [%{role: "user", content: "What is Elixir?"}]
})

# Execute the run -- this calls the provider and streams events
{:ok, result} = SessionManager.execute_run(store, adapter, run.id)

# The result contains the output, token usage, and events
IO.puts(result.output.content)
IO.inspect(result.token_usage)
# => %{input_tokens: 15, output_tokens: 120}

# Complete the session when done
{:ok, _} = SessionManager.complete_session(store, session.id)
```

## Understanding the Workflow

Here's what happens under the hood when you call `SessionManager.execute_run/3`:

1. The run is fetched from the store and its status updated to `:running`
2. The parent session is fetched for context
3. The provider adapter's `execute/4` is called with the run and session
4. The adapter sends the request to the AI provider
5. As the provider streams back responses, the adapter emits normalized events
6. Each event is persisted to the session store via `append_event_with_sequence/2`
7. Telemetry events are emitted for observability
8. When the provider finishes, the run/session are finalized and persisted via `flush/2`
9. The result is returned to the caller

## Using the Event Callback

You can react to events in real time by providing an event callback when executing through the adapter directly:

```elixir
callback = fn event ->
  case event.type do
    :message_streamed ->
      IO.write(event.data.delta)

    :tool_call_started ->
      IO.puts("Calling tool: #{event.data.tool_name}")

    :run_completed ->
      IO.puts("\nDone!")

    _ ->
      :ok
  end
end

{:ok, result} = ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
```

## Working Without a Provider

You can use the core domain types without any provider adapter -- they are pure data structures:

```elixir
alias AgentSessionManager.Core.{Session, Run, Event}

# Create domain objects
{:ok, session} = Session.new(%{agent_id: "test-agent"})
{:ok, run} = Run.new(%{session_id: session.id})
{:ok, event} = Event.new(%{
  type: :message_received,
  session_id: session.id,
  run_id: run.id,
  data: %{content: "Hello"}
})

# Serialize to maps for storage or transmission
session_map = Session.to_map(session)
run_map = Run.to_map(run)
event_map = Event.to_map(event)

# Reconstruct from maps
{:ok, restored_session} = Session.from_map(session_map)
```

## Running the Examples

The `examples/` directory has runnable scripts that demonstrate the library end-to-end:

```bash
# Live mode with real providers
mix run examples/live_session.exs --provider claude
mix run examples/live_session.exs --provider codex

# Provider-agnostic common surface (identical code for both providers)
mix run examples/common_surface.exs --provider claude

# Contract-surface verification (events + completion payload)
mix run examples/contract_surface_live.exs --provider claude

# Claude-specific SDK features (Orchestrator, Streaming, Hooks, Agent profiles)
mix run examples/claude_direct.exs --section orchestrator

# Codex-specific SDK features (Threads, Options, Sessions)
mix run examples/codex_direct.exs --section threads
```

## Next Steps

- [Live Examples](live_examples.md) -- run the full live example suite and validate contract behavior
- [Architecture](architecture.md) -- understand the ports & adapters design
- [Configuration](configuration.md) -- layered config with process-local overrides
- [Sessions and Runs](sessions_and_runs.md) -- deep dive into lifecycle management
- [Session Server Runtime](session_server_runtime.md) -- per-session FIFO queueing and subscriptions
- [Cursor Streaming](cursor_streaming_and_migration.md) -- durable sequence numbers and cursor queries
- [Session Continuity](session_continuity.md) -- transcript reconstruction and cross-run context
- [Workspace Snapshots](workspace_snapshots.md) -- pre/post snapshots, diffs, and rollback
- [Provider Routing](provider_routing.md) -- capability-based selection and failover
- [Policy Enforcement](policy_enforcement.md) -- budget/tool governance per execution
- [Advanced Patterns](advanced_patterns.md) -- cross-feature integration examples
- [Provider Adapters](provider_adapters.md) -- configure Claude, Codex, or Amp, or write your own
