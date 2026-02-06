<p align="center">
  <img src="assets/agent_session_manager.svg" alt="AgentSessionManager" width="200">
</p>

<h1 align="center">AgentSessionManager</h1>

<p align="center">
  An Elixir library for managing AI agent sessions with state persistence, streaming events, multi-provider support, and concurrency controls.
</p>

<p align="center">
  <a href="https://hex.pm/packages/agent_session_manager"><img src="https://img.shields.io/hexpm/v/agent_session_manager.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/agent_session_manager"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="Documentation"></a>
  <a href="https://github.com/nshkrdotcom/agent_session_manager/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

---

## What It Does

AgentSessionManager provides the infrastructure layer for building applications that interact with AI agents. Rather than calling provider APIs directly, you work with sessions, runs, and events -- giving you lifecycle management, observability, and the ability to swap providers without rewriting your application.

**Key features:**

- **Session & run lifecycle** -- Create sessions, execute runs, and track state transitions with a well-defined state machine
- **Multi-provider support** -- Built-in adapters for Claude Code (Anthropic) and Codex, with a behaviour for adding your own
- **Streaming events** -- Normalized event pipeline that maps provider-specific events to a canonical format
- **Capability negotiation** -- Declare required and optional capabilities; the resolver checks provider support before execution
- **Concurrency controls** -- Configurable limits on parallel sessions and runs with slot-based tracking
- **Observability** -- Telemetry integration, audit logging, and append-only event stores
- **Ports & adapters architecture** -- Clean separation between core logic and external dependencies

## Architecture Overview

```
Your Application
       |
  SessionManager         -- orchestrates lifecycle, events, capability checks
       |
  +----+----+
  |         |
Store    Adapter          -- ports (interfaces / behaviours)
  |         |
ETS/DB   Claude/Codex     -- adapters (implementations)
```

The core domain types (`Session`, `Run`, `Event`, `Capability`, `Manifest`) are pure data structures with no side effects. The `SessionManager` coordinates between the storage port and the provider adapter port.

## Installation

Add `agent_session_manager` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.2.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

### One-shot (simplest)

```elixir
alias AgentSessionManager.SessionManager
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}

{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))

{:ok, result} = SessionManager.run_once(store, adapter, %{
  messages: [%{role: "user", content: "Hello!"}]
}, event_callback: fn e -> IO.inspect(e.type) end)

IO.puts(result.output.content)
IO.inspect(result.token_usage)
# result also includes :session_id and :run_id
```

### Full lifecycle

```elixir
alias AgentSessionManager.SessionManager
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}

# 1. Start the storage and adapter processes
{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link(api_key: System.get_env("ANTHROPIC_API_KEY"))

# 2. Create and activate a session
{:ok, session} = SessionManager.start_session(store, adapter, %{
  agent_id: "my-agent",
  context: %{system_prompt: "You are a helpful assistant."}
})
{:ok, session} = SessionManager.activate_session(store, session.id)

# 3. Create and execute a run
{:ok, run} = SessionManager.start_run(store, adapter, session.id, %{
  messages: [%{role: "user", content: "Hello!"}]
})
{:ok, result} = SessionManager.execute_run(store, adapter, run.id)

# 4. Inspect the result
IO.puts(result.output.content)
IO.inspect(result.token_usage)

# 5. Complete the session
{:ok, _} = SessionManager.complete_session(store, session.id)
```

## Core Concepts

### Sessions

A session is a logical container for a series of interactions with an AI agent. Sessions track state (`pending -> active -> completed/failed/cancelled`) and carry context (system prompts, metadata, tags).

```elixir
{:ok, session} = Session.new(%{agent_id: "research-agent", tags: ["research"]})
{:ok, active} = Session.update_status(session, :active)
```

### Runs

A run represents one execution within a session -- sending input to the provider and receiving output. Runs have their own lifecycle (`pending -> running -> completed/failed/cancelled/timeout`) and track token usage.

```elixir
{:ok, run} = Run.new(%{session_id: session.id, input: %{messages: messages}})
{:ok, completed} = Run.set_output(run, %{content: "Response text"})
```

### Events

Events are immutable records of things that happen during execution. They provide an audit trail and power the streaming interface.

```elixir
{:ok, event} = Event.new(%{
  type: :message_received,
  session_id: session.id,
  run_id: run.id,
  data: %{content: "Hello!", role: "assistant"}
})
```

### Provider Adapters

Adapters implement the `ProviderAdapter` behaviour to integrate with AI providers. Each adapter handles streaming, tool calls, and cancellation for its provider.

| Adapter | Provider | Streaming | Tool Use | Cancel |
|---------|----------|-----------|----------|--------|
| `ClaudeAdapter` | Anthropic | Yes | Yes | Yes |
| `CodexAdapter` | Codex CLI | Yes | Yes | Yes |

### Capability Negotiation

Before starting a run, you can declare what capabilities are required. The resolver checks the provider's capabilities and fails fast if requirements aren't met.

```elixir
{:ok, resolver} = CapabilityResolver.new(required: [:sampling], optional: [:tool])
{:ok, result} = CapabilityResolver.negotiate(resolver, adapter_capabilities)
# result.status => :full | :degraded
```

## Provider Event Normalization

Each provider emits events in its own format. The adapters normalize these into a canonical set:

| Normalized Event | Description |
|---|---|
| `run_started` | Execution began |
| `message_streamed` | Streaming content chunk |
| `message_received` | Complete message ready |
| `tool_call_started` | Tool invocation begins |
| `tool_call_completed` | Tool finished |
| `token_usage_updated` | Usage stats updated |
| `run_completed` | Execution finished |
| `run_failed` | Execution failed |
| `run_cancelled` | Execution cancelled |

## Error Handling

All operations return tagged tuples. Errors use a structured taxonomy with machine-readable codes:

```elixir
case SessionManager.start_session(store, adapter, attrs) do
  {:ok, session} -> session
  {:error, %Error{code: :validation_error, message: msg}} ->
    Logger.error("Validation failed: #{msg}")
end
```

Error codes are grouped into categories: validation, resource, provider, storage, runtime, concurrency, and tool errors. Some errors (like `provider_timeout`) are marked retryable via `Error.retryable?/1`.

## Examples

The `examples/` directory contains runnable scripts:

```bash
# Run with mock mode (no API key needed)
mix run examples/live_session.exs --provider claude --mock

# Run with real API
ANTHROPIC_API_KEY=sk-ant-... mix run examples/live_session.exs --provider claude

# One-shot execution (simplest example)
mix run examples/oneshot.exs --provider claude

# Provider-agnostic common surface (works with either provider)
mix run examples/common_surface.exs --provider claude
mix run examples/common_surface.exs --provider codex

# Claude-specific SDK features (Orchestrator, Streaming, Hooks, Agent profiles)
mix run examples/claude_direct.exs
mix run examples/claude_direct.exs --section orchestrator

# Codex-specific SDK features (Threads, Options, Sessions)
mix run examples/codex_direct.exs
mix run examples/codex_direct.exs --section threads
```

See `examples/README.md` for full documentation.

## Guides

The guides cover each subsystem in depth:

- [Getting Started](guides/getting_started.md) -- Installation, first session, and core workflow
- [Architecture](guides/architecture.md) -- Ports & adapters design, module map, data flow
- [Configuration](guides/configuration.md) -- Layered config system, process-local overrides
- [Sessions and Runs](guides/sessions_and_runs.md) -- Lifecycle state machines, metadata, context
- [Events and Streaming](guides/events_and_streaming.md) -- Event types, normalization, EventStream cursor
- [Provider Adapters](guides/provider_adapters.md) -- Using Claude/Codex adapters, writing your own
- [Capabilities](guides/capabilities.md) -- Defining capabilities, negotiation, manifests, registry
- [Concurrency](guides/concurrency.md) -- Session/run limits, slot management, control operations
- [Telemetry and Observability](guides/telemetry_and_observability.md) -- Telemetry events, audit logging, metrics
- [Error Handling](guides/error_handling.md) -- Error taxonomy, retryable errors, provider errors
- [Testing](guides/testing.md) -- Mock adapters, in-memory store, testing patterns

## Documentation

Full API documentation is available at [HexDocs](https://hexdocs.pm/agent_session_manager).

## License

AgentSessionManager is released under the [MIT License](LICENSE).
