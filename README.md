<p align="center">
  <img src="assets/agent_session_manager.svg" alt="AgentSessionManager" width="200">
</p>

<h1 align="center">AgentSessionManager</h1>

<p align="center">
  Unified Elixir infrastructure for orchestrating AI agent sessions across Claude, Codex, and Amp &mdash; with lifecycle management, event streaming, persistence, and provider-agnostic observability.
</p>

<p align="center">
  <a href="https://hex.pm/packages/agent_session_manager"><img src="https://img.shields.io/hexpm/v/agent_session_manager.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/agent_session_manager"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="Documentation"></a>
  <a href="https://github.com/nshkrdotcom/agent_session_manager/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

---

## Why AgentSessionManager?

When you call an AI provider API directly, you get back a response. When you build a *product* on top of AI agents, you need much more: session state, event history, cost tracking, cancellation, persistence, and the ability to swap providers without rewriting your application.

AgentSessionManager is the infrastructure layer that gives you all of this through a clean ports-and-adapters architecture.

| Concern | Without ASM | With ASM |
|---------|-------------|----------|
| Session state | Hand-roll per provider | Unified lifecycle with state machines |
| Event formats | Parse each provider separately | 20+ normalized event types |
| Persistence | Build your own | Pluggable: InMemory, Ecto (Postgres/SQLite), Ash, S3 |
| Cost visibility | None | Model-aware cost tracking per run |
| Provider lock-in | Rewrite when switching | Swap adapters, keep application code |
| Observability | Ad-hoc logging | Telemetry, rendering pipeline, audit trail |

See [Architecture](guides/architecture.md) for the full design.

## Quick Start

Add the dependency and at least one provider SDK:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"},
    {:claude_agent_sdk, "~> 0.13.0"}  # or {:codex_sdk, "~> 0.9.0"} / {:amp_sdk, "~> 0.3"}
  ]
end
```

Run a one-shot session:

```elixir
alias AgentSessionManager.SessionManager
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}

{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link()

{:ok, result} =
  SessionManager.run_once(store, adapter,
    %{messages: [%{role: "user", content: "What is the BEAM?"}]},
    event_callback: fn
      %{type: :message_streamed, data: %{delta: text}} -> IO.write(text)
      _ -> :ok
    end
  )

IO.inspect(result.token_usage)
```

This creates a session, executes one run, streams events, and cleans up. For provider-specific setup, see [Provider Adapters](guides/provider_adapters.md).

## Choose Your Abstraction Level

Start with the simplest API that meets your needs:

| API | Use when you need | Complexity |
|-----|-------------------|------------|
| `SessionManager.run_once/4` | Single request/response, scripts, testing | Lowest |
| `StreamSession.start/1` | Lazy event stream from a one-shot call | Low |
| `SessionManager` full lifecycle | Multi-run sessions, explicit state control | Medium |
| `SessionServer` | Per-session queuing, concurrent runs, subscriptions | Highest |

### StreamSession

Collapses boilerplate into a single call that returns a lazy stream:

```elixir
{:ok, stream, close, _meta} =
  StreamSession.start(
    adapter: {ClaudeAdapter, []},
    input: %{messages: [%{role: "user", content: "Hello!"}]}
  )

stream |> Stream.each(&IO.inspect/1) |> Stream.run()
close.()
```

See [StreamSession](guides/stream_session.md).

### Full Lifecycle

Explicit control over session creation, activation, runs, and completion:

```elixir
{:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "my-agent"})
{:ok, session} = SessionManager.activate_session(store, session.id)
{:ok, run} = SessionManager.start_run(store, adapter, session.id, %{messages: messages})
{:ok, result} = SessionManager.execute_run(store, adapter, run.id)
{:ok, _} = SessionManager.complete_session(store, session.id)
```

See [Sessions and Runs](guides/sessions_and_runs.md).

### SessionServer

Per-session GenServer with FIFO queuing and multi-slot concurrency:

```elixir
{:ok, server} =
  SessionServer.start_link(
    store: store,
    adapter: adapter,
    session_opts: %{agent_id: "runtime-agent"},
    max_concurrent_runs: 2
  )

{:ok, run_id} = SessionServer.submit_run(server, %{messages: messages})
{:ok, result} = SessionServer.await_run(server, run_id, 120_000)
:ok = SessionServer.drain(server, 30_000)
```

See [Session Server Runtime](guides/session_server_runtime.md).

## Core Concepts

```
Your Application
       |
  SessionManager         -- orchestrates lifecycle, events, capability checks
       |
  +----+----+
  |         |
Store    Adapter          -- ports (interfaces / behaviours)
  |         |
ETS/DB   Claude/Codex/Amp -- adapters (implementations)
```

**Sessions** are containers for a series of agent interactions. State machine: `pending -> active -> completed / failed / cancelled`.

**Runs** represent one execution within a session -- sending input and receiving output. State machine: `pending -> running -> completed / failed / cancelled / timeout`. Runs track token usage and output.

**Events** are immutable records emitted during execution. They provide an audit trail, power streaming, and enable cursor-based replay.

### Ports

The core depends only on behaviours. Swap implementations without touching application code.

| Port | Purpose |
|------|---------|
| `ProviderAdapter` | AI provider integration (execute, cancel, capabilities) |
| `SessionStore` | Session, run, and event persistence |
| `ArtifactStore` | Binary artifact storage (patches, files) |
| `QueryAPI` | Cross-session queries and analytics |
| `Maintenance` | Retention, cleanup, health checks |

## Providers

| Adapter | Provider | Streaming | Tool Use | Cancel |
|---------|----------|-----------|----------|--------|
| `ClaudeAdapter` | Anthropic Claude | Yes | Yes | Yes |
| `CodexAdapter` | Codex CLI | Yes | Yes | Yes |
| `AmpAdapter` | Amp (Sourcegraph) | Yes | Yes | Yes |
| `ShellAdapter` | Shell commands | Yes | No | Yes |

All adapters accept `:permission_mode`, `:max_turns`, `:system_prompt`, and `:sdk_opts` for provider-specific passthrough. For multi-provider setups, `ProviderRouter` acts as a meta-adapter with capability-based selection, failover, and circuit breaker. See [Provider Routing](guides/provider_routing.md).

### Normalized Events

Each provider emits events in its own format. Adapters normalize them into a canonical set:

| Event | Description |
|-------|-------------|
| `run_started` | Execution began |
| `message_streamed` | Streaming content chunk |
| `message_received` | Complete message ready |
| `tool_call_started` | Tool invocation begins |
| `tool_call_completed` | Tool finished |
| `token_usage_updated` | Usage stats updated |
| `run_completed` | Execution finished successfully |
| `run_failed` | Execution failed |
| `run_cancelled` | Execution cancelled |
| `policy_violation` | Policy limit exceeded |

See [Events and Streaming](guides/events_and_streaming.md) for the full event type reference.

## Features

### Persistence and Storage

Pluggable storage backends for sessions, runs, events, and artifacts. `InMemorySessionStore` for development and testing; `EctoSessionStore` for PostgreSQL or SQLite in production; `AshSessionStore` as an Ash Framework alternative; `S3ArtifactStore` for large binary artifacts; `CompositeSessionStore` to unify session and artifact backends.

```elixir
# Production setup with Ecto + SQLite
{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)
```

Guides: [Persistence Overview](guides/persistence_overview.md) | [Ecto](guides/ecto_session_store.md) | [SQLite](guides/sqlite_session_store.md) | [Ash](guides/ash_session_store.md) | [S3](guides/s3_artifact_store.md) | [Custom](guides/custom_persistence_guide.md)

### Event Streaming and Observability

Cursor-backed event streaming with monotonic per-session sequence numbers, durable pagination (`after`/`before`/`limit`), and optional long-poll support. The rendering pipeline separates formatting (renderers) from output (sinks) -- compose `StudioRenderer`, `CompactRenderer`, or `VerboseRenderer` with `TTYSink`, `FileSink`, `JSONLSink`, `PubSubSink`, or `CallbackSink`.

```elixir
Rendering.stream(event_stream,
  renderer: {StudioRenderer, verbosity: :summary},
  sinks: [{TTYSink, []}, {JSONLSink, path: "events.jsonl"}]
)
```

Guides: [Events and Streaming](guides/events_and_streaming.md) | [Cursor Streaming](guides/cursor_streaming_and_migration.md) | [Rendering](guides/rendering.md) | [Telemetry](guides/telemetry_and_observability.md)

### Session Continuity and Workspace

**Continuity**: Provider-agnostic transcript reconstruction from persisted events. Continuation modes (`:auto`, `:replay`, `:native`) with token-aware truncation keep conversations within budget across runs.

**Workspace**: Optional pre/post snapshots with git or hash backends. Computes diffs, captures patches as artifacts, and supports rollback on failure (git backend only).

Guides: [Session Continuity](guides/session_continuity.md) | [Workspace Snapshots](guides/workspace_snapshots.md)

### Routing, Policy, and Cost

**Routing**: `ProviderRouter` selects providers by capability matching, with health tracking, failover, weighted scoring, session stickiness, and circuit breaker.

**Policy**: Real-time budget and tool governance. Define token, duration, and cost limits with tool allow/deny rules. Violations trigger `:cancel` or `:warn` actions. Policies stack with deterministic merge.

**Cost**: Model-aware cost calculation using configurable pricing tables. Integrates with policy enforcement for budget limits.

```elixir
{:ok, policy} = Policy.new(
  name: "production",
  limits: [{:max_total_tokens, 8_000}, {:max_cost_usd, 0.50}],
  tool_rules: [{:deny, ["bash"]}],
  on_violation: :cancel
)
```

Guides: [Provider Routing](guides/provider_routing.md) | [Policy Enforcement](guides/policy_enforcement.md) | [Cost Tracking](guides/cost_tracking.md)

### Concurrency, PubSub, and Integration

**Concurrency**: `ConcurrencyLimiter` enforces max parallel sessions/runs. `SessionServer` provides per-session FIFO queuing with multi-slot execution and durable subscriptions.

**PubSub**: Phoenix.PubSub integration for real-time event broadcasting to LiveView, WebSocket, or other subscribers.

**Workflow Bridge**: Thin integration layer for DAG/workflow engines with step execution, error classification (retry/failover/abort), and multi-run session lifecycle helpers.

**Secrets Redaction**: `EventRedactor` strips sensitive data from events before persistence.

Guides: [Concurrency](guides/concurrency.md) | [PubSub](guides/pubsub_integration.md) | [Workflow Bridge](guides/workflow_bridge.md) | [Secrets Redaction](guides/secrets_redaction.md) | [Shell Runner](guides/shell_runner.md)

## Guides

### Introduction

- [Getting Started](guides/getting_started.md) -- Installation, first session, core workflow
- [Live Examples](guides/live_examples.md) -- Running examples and validating contract surfaces
- [Architecture](guides/architecture.md) -- Ports & adapters design, module map, data flow
- [Configuration](guides/configuration.md) -- Layered config system, process-local overrides
- [Configuration Reference](guides/configuration_reference.md) -- Complete config key reference
- [Model Configuration](guides/model_configuration.md) -- Provider-specific model selection

### Core Concepts

- [Sessions and Runs](guides/sessions_and_runs.md) -- Lifecycle state machines, metadata, serialization
- [Session Server Runtime](guides/session_server_runtime.md) -- FIFO queuing, multi-slot concurrency, drain/status
- [Session Server Subscriptions](guides/session_server_subscriptions.md) -- Durable subscriptions with backfill and filtering
- [Session Continuity](guides/session_continuity.md) -- Transcript reconstruction, continuation modes
- [Events and Streaming](guides/events_and_streaming.md) -- Event types, normalization, EventStream cursor
- [Rendering](guides/rendering.md) -- Renderer x Sink pipeline for event output
- [PubSub Integration](guides/pubsub_integration.md) -- Real-time event broadcasting
- [Stream Session](guides/stream_session.md) -- One-shot streaming with lazy consumption
- [Cursor Streaming and Migration](guides/cursor_streaming_and_migration.md) -- Sequence numbers, cursor APIs
- [Workspace Snapshots](guides/workspace_snapshots.md) -- Snapshots, diffs, rollback, artifact storage
- [Provider Routing](guides/provider_routing.md) -- Capability matching, failover, circuit breaker
- [Policy Enforcement](guides/policy_enforcement.md) -- Limits, tool rules, violation actions
- [Cost Tracking](guides/cost_tracking.md) -- Model-aware pricing, budget enforcement
- [Advanced Patterns](guides/advanced_patterns.md) -- Cross-feature integration patterns
- [Capabilities](guides/capabilities.md) -- Capability negotiation, manifests, registry

### Persistence

- [Persistence Overview](guides/persistence_overview.md) -- Ports, adapters, event persistence flow
- [Migrating to v0.8](guides/migrating_to_v0.8.md) -- Breaking changes and new patterns
- [Ecto SessionStore](guides/ecto_session_store.md) -- PostgreSQL and SQLite via Ecto
- [Ash SessionStore](guides/ash_session_store.md) -- Ash resources and AshPostgres
- [SQLite with Ecto](guides/sqlite_session_store.md) -- Zero-dependency file-backed persistence
- [S3 ArtifactStore](guides/s3_artifact_store.md) -- S3-compatible object storage
- [Composite Store](guides/composite_store.md) -- Unified session + artifact backend
- [Event Schema Versioning](guides/event_schema_versioning.md) -- Schema evolution strategy
- [Secrets Redaction](guides/secrets_redaction.md) -- Redact sensitive data before persistence
- [Custom Persistence](guides/custom_persistence_guide.md) -- Implementing your own adapters

### Integration

- [Provider Adapters](guides/provider_adapters.md) -- Claude, Codex, Amp setup and custom adapters
- [Workflow Bridge](guides/workflow_bridge.md) -- DAG/workflow engine integration
- [Shell Runner](guides/shell_runner.md) -- ShellAdapter for command execution
- [Concurrency](guides/concurrency.md) -- Limiter, control operations
- [Telemetry and Observability](guides/telemetry_and_observability.md) -- Telemetry events, metrics

### Reference

- [Error Handling](guides/error_handling.md) -- Error taxonomy, retryable errors
- [Testing](guides/testing.md) -- Mock adapters, in-memory store, test patterns

## Production Checklist

**Required:**

- [ ] Replace `InMemorySessionStore` with [`EctoSessionStore`](guides/ecto_session_store.md) or [`AshSessionStore`](guides/ash_session_store.md)
- [ ] Run schema migrations (`EctoSessionStore.Migration.up/0`)
- [ ] Configure provider API keys (see [Provider Adapters](guides/provider_adapters.md))

**Recommended:**

- [ ] Enable [cost tracking](guides/cost_tracking.md) with pricing tables
- [ ] Enable [secrets redaction](guides/secrets_redaction.md) before persistence
- [ ] Define [policies](guides/policy_enforcement.md) for token and cost limits
- [ ] Wire up [telemetry](guides/telemetry_and_observability.md) handlers for metrics
- [ ] Use `SessionServer` for [per-session queuing](guides/session_server_runtime.md) in long-running applications

**Optional:**

- [ ] [S3 artifact storage](guides/s3_artifact_store.md) for workspace patches
- [ ] [PubSub integration](guides/pubsub_integration.md) for real-time fanout to LiveView/WebSocket
- [ ] [Provider routing](guides/provider_routing.md) for multi-provider setups
- [ ] [Workspace snapshots](guides/workspace_snapshots.md) for tracking file changes
- [ ] [Ash Framework](guides/ash_session_store.md) for resource-oriented persistence

## Error Handling

All operations return tagged tuples. Errors use a structured taxonomy with machine-readable codes:

```elixir
case SessionManager.start_session(store, adapter, attrs) do
  {:ok, session} -> session
  {:error, %Error{code: :validation_error, message: msg}} ->
    Logger.error("Validation failed: #{msg}")
end
```

Error codes are grouped into categories: validation, resource, provider, storage, runtime, concurrency, and tool errors. Some errors are marked retryable via `Error.retryable?/1`. See [Error Handling](guides/error_handling.md).

## Examples

The `examples/` directory contains 40+ runnable scripts. Run them all:

```bash
bash examples/run_all.sh
# Or for a single provider:
bash examples/run_all.sh --provider claude
```

**Getting started:** `oneshot.exs`, `live_session.exs`, `stream_session.exs`, `common_surface.exs`

**Provider-specific:** `claude_direct.exs`, `codex_direct.exs`, `amp_direct.exs`

**Features:** `session_continuity.exs`, `workspace_snapshot.exs`, `provider_routing.exs`, `policy_enforcement.exs`, `cost_tracking.exs`, `rendering_studio.exs`, `approval_gates.exs`, `secrets_redaction.exs`

**Persistence:** `persistence_live.exs`, `sqlite_session_store_live.exs`, `ecto_session_store_live.exs`, `ash_session_store.exs`, `composite_store_live.exs`

**Advanced:** `session_concurrency.exs`, `interactive_interrupt.exs`, `workflow_bridge.exs`, `shell_exec.exs`, `pubsub_sink.exs`

See [`examples/README.md`](examples/README.md) for full documentation.

## Documentation

Full API documentation is available at [HexDocs](https://hexdocs.pm/agent_session_manager).

## License

AgentSessionManager is released under the [MIT License](LICENSE).
