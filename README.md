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
- **Multi-provider support** -- Built-in adapters for Claude Code (Anthropic), Codex, and Amp (Sourcegraph), with a behaviour for adding your own
- **Streaming events** -- Normalized event pipeline that maps provider-specific events to a canonical format
- **Cursor-backed event streaming** -- Monotonic per-session sequence numbers with durable cursor queries (`after` / `before`) and optional long-poll support (`wait_timeout_ms`)
- **Session continuity** -- Provider-agnostic transcript reconstruction, continuation modes (`:auto`, `:replay`, `:native`), per-provider session handles, and token-aware transcript truncation
- **Workspace snapshots** -- Optional pre/post snapshots (including untracked files), diff summaries, patch capture caps, artifact-backed patch storage, configurable ignore rules, and git-only rollback on failure
- **Provider routing** -- Router-as-adapter with capability-based selection, policy ordering, retryable failover, weighted scoring, session stickiness, circuit breaker, and routing telemetry
- **Policy enforcement** -- Real-time budget/tool governance with cancel or warn actions, `:policy_violation` events, policy stacking with deterministic merge, provider-side enforcement, and preflight checks
- **Capability negotiation** -- Declare required and optional capabilities; the resolver checks provider support before execution
- **Concurrency controls** -- Configurable limits on parallel sessions and runs with slot-based tracking
- **Session server runtime** -- Optional per-session `SessionServer` with FIFO queueing, multi-slot concurrency (`max_concurrent_runs`), durable subscriptions with backfill, drain/status operational APIs, and optional `ConcurrencyLimiter` / `ControlOperations` integration
- **Rendering pipeline** -- Pluggable Renderer x Sink architecture for formatting and outputting events to terminals, files, JSONL, or custom callbacks
- **Observability** -- Telemetry integration, audit logging, and append-only event stores
- **Durable persistence semantics** -- Events are appended with atomic sequencing, and `SessionStore.flush/2` is used at run finalization to atomically persist the final run/session state in transactional backends
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
ETS/DB   Claude/Codex/Amp -- adapters (implementations)
```

The core domain types (`Session`, `Run`, `Event`, `Capability`, `Manifest`) are pure data structures with no side effects. The `SessionManager` coordinates between the storage port and the provider adapter port.

`run_once/4` accepts any `SessionStore` reference supported by the port:
pid/name (GenServer-backed stores) or `{Module, context}` (module-backed refs).

## Installation

Add `agent_session_manager` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

Provider SDK integrations (`claude_agent_sdk`, `codex_sdk`, `amp_sdk`) are optional.
If you are building a persistence-only deployment, you can install just the SQL/object-store dependencies you use.

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"},
    {:ecto_sql, "~> 3.12"},
    {:ecto_sqlite3, "~> 0.17"} # or {:postgrex, "~> 0.19"}
  ]
end
```

For `EctoSessionStore`, run both schema migrations in order:

1. `AgentSessionManager.Adapters.EctoSessionStore.Migration.up/0`
2. `AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.up/0`

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

### Session runtime (queued, concurrent)

If you need a per-session runtime that queues runs and provides await/cancel and subscriptions, use `AgentSessionManager.Runtime.SessionServer`.

Supports sequential (`max_concurrent_runs: 1`) or multi-slot parallel execution.

```elixir
alias AgentSessionManager.Adapters.{ClaudeAdapter, InMemorySessionStore}
alias AgentSessionManager.Runtime.SessionServer

{:ok, store} = InMemorySessionStore.start_link()
{:ok, adapter} = ClaudeAdapter.start_link(model: "claude-haiku-4-5-20251001", tools: [])

{:ok, server} =
  SessionServer.start_link(
    store: store,
    adapter: adapter,
    session_opts: %{agent_id: "runtime-session"},
    max_concurrent_runs: 2   # up to 2 runs in parallel
  )

{:ok, run_id} =
  SessionServer.submit_run(server, %{
    messages: [%{role: "user", content: "Hello!"}]
  })

{:ok, result} = SessionServer.await_run(server, run_id, 120_000)
IO.inspect(result.output)

# Drain: wait for all in-flight and queued runs to complete
:ok = SessionServer.drain(server, 30_000)
```

### StreamSession (one-shot streaming)

For consumers that just need a lazy event stream from a one-shot session, `StreamSession` eliminates the boilerplate:

```elixir
alias AgentSessionManager.Adapters.ClaudeAdapter
alias AgentSessionManager.StreamSession

{:ok, stream, close_fun, _meta} =
  StreamSession.start(
    adapter: {ClaudeAdapter, []},
    input: %{messages: [%{role: "user", content: "Hello!"}]}
  )

stream |> Stream.each(&IO.inspect/1) |> Stream.run()
close_fun.()
```

StreamSession handles store creation, adapter startup, task management, error events, and cleanup. See `guides/stream_session.md` for full documentation.

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

### Cursor-Backed Streaming

Event sequence numbers are assigned at append time by the `SessionStore` implementation.
This makes event ordering durable and resumable across processes.

```elixir
alias AgentSessionManager.Ports.SessionStore

{:ok, stored_event} = SessionStore.append_event_with_sequence(store, event)
stored_event.sequence_number
# => 42

{:ok, latest} = SessionStore.get_latest_sequence(store, session.id)
# => 42
```

`SessionStore.get_events/3` supports cursor filters in addition to existing filters:

```elixir
# Cursor pagination
{:ok, page_1} = SessionStore.get_events(store, session.id, limit: 50)
cursor = List.last(page_1).sequence_number
{:ok, page_2} = SessionStore.get_events(store, session.id, after: cursor, limit: 50)

# Bounded window
{:ok, window} = SessionStore.get_events(store, session.id, after: 100, before: 200)
```

For follow/poll consumption, use `SessionManager.stream_session_events/3`:

```elixir
# Polling mode (default)
stream =
  SessionManager.stream_session_events(store, session.id,
    after: 0,
    limit: 100,
    poll_interval_ms: 250
  )

Enum.take(stream, 10)

# Long-poll mode (no busy polling — the store blocks until events arrive)
stream =
  SessionManager.stream_session_events(store, session.id,
    after: cursor,
    limit: 100,
    wait_timeout_ms: 5_000
  )

Enum.take(stream, 10)
```

The long-poll mode is useful for real-time streaming UIs (SSE/WebSocket) where
you want lower latency without wasting CPU on frequent empty polls.

Adapter events also preserve provider timestamps and metadata:

```elixir
{:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
event = Enum.find(events, &(&1.type == :run_started))
event.metadata[:provider]  # => "claude"
event.timestamp            # => adapter-provided timestamp (when available)
```

### Session Continuity

Continuity is opt-in per run. When enabled, `SessionManager` reconstructs a
transcript from persisted events and injects it into `session.context[:transcript]`
before calling the adapter.

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto,
  continuation_opts: [max_messages: 200, max_tokens_approx: 12_000]
)
```

Continuation modes: `false` (disabled), `true` / `:auto` (replay fallback),
`:replay` (always replay), `:native` (provider-native, errors if unavailable).

Token-aware truncation keeps the most recent messages within a character or
approximate token budget (`max_chars`, `max_tokens_approx`).

Adapters consume transcript context when present. Per-provider session handles
are tracked under `session.metadata[:provider_sessions]`.

### Workspace Snapshots

Workspace instrumentation is also opt-in per run:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  workspace: [
    enabled: true,
    path: "/path/to/workspace",
    strategy: :auto,
    capture_patch: true,
    max_patch_bytes: 1_048_576,
    rollback_on_failure: false,
    artifact_store: artifact_store,
    ignore: [paths: ["vendor"], globs: ["*.log"]]
  ]
)
```

When enabled, `SessionManager` takes pre/post snapshots, computes diffs,
emits workspace events, and enriches run metadata with compact diff summaries.

Git snapshots capture the full workspace state including untracked files without
mutating `HEAD`. When an `artifact_store` is configured, large patches are stored
as artifacts and only a `patch_ref` is kept in metadata. Hash backend supports
configurable ignore rules via `ignore: [paths: [...], globs: [...]]`.

Rollback is git-only. Requesting `rollback_on_failure: true` with hash backend
returns a configuration error.

### Provider Routing

`ProviderRouter` is a normal `ProviderAdapter`, so no `SessionManager` branching is required.

```elixir
alias AgentSessionManager.Routing.ProviderRouter

{:ok, router} =
  ProviderRouter.start_link(
    policy: [prefer: ["amp", "codex", "claude"], max_attempts: 3],
    cooldown_ms: 30_000
  )

:ok = ProviderRouter.register_adapter(router, "claude", claude_adapter)
:ok = ProviderRouter.register_adapter(router, "codex", codex_adapter)
:ok = ProviderRouter.register_adapter(router, "amp", amp_adapter)

{:ok, result} =
  SessionManager.execute_run(store, router, run.id,
    adapter_opts: [
      routing: [
        required_capabilities: [%{type: :tool, name: "bash"}]
      ]
    ]
  )
```

MVP health/failover behavior:

- tracks consecutive failures and last failure time per adapter
- applies cooldown-based temporary skipping
- retries/fails over only for retryable errors (`Error.retryable?/1`)
- routes `cancel/2` to the adapter currently handling the active run

Phase 2 additions:

- **Weighted scoring** -- `strategy: :weighted` with custom weights and health-based penalties
- **Session stickiness** -- `sticky_session_id` binds sessions to adapters across runs with configurable TTL
- **Circuit breaker** -- pure-functional per-adapter circuit breaker (closed/open/half-open states)
- **Routing telemetry** -- `:telemetry` events for each routing attempt (start/stop/exception)

### Policy Enforcement

Policy enforcement is opt-in per execution:

```elixir
alias AgentSessionManager.Policy.Policy

{:ok, policy} =
  Policy.new(
    name: "production",
    limits: [{:max_total_tokens, 8_000}, {:max_duration_ms, 120_000}],
    tool_rules: [{:deny, ["bash"]}],
    on_violation: :cancel
  )

{:ok, result} =
  SessionManager.execute_run(store, adapter, run.id, policy: policy)
```

Behavior:

- violations emit `:policy_violation` events
- `on_violation: :cancel` triggers one cancellation request and returns
  `{:error, %Error{code: :policy_violation}}` even if provider returned success
- `on_violation: :warn` preserves success and returns violation metadata in `result.policy`
- cost limits (`{:max_cost_usd, ...}`) are optional and use configured provider token rates

Phase 2 additions:

- **Policies stack** -- `policies: [org, team, user]` with deterministic merge (strictest `on_violation` wins)
- **Provider-side enforcement** -- policy rules compiled to `adapter_opts` for best-effort provider-side hints
- **Preflight checks** -- impossible policies (empty allow lists, zero budgets) rejected before adapter execution

### Provider Adapters

Adapters implement the `ProviderAdapter` behaviour to integrate with AI providers. Each adapter handles streaming, tool calls, and cancellation for its provider.

| Adapter | Provider | Streaming | Tool Use | Cancel |
|---------|----------|-----------|----------|--------|
| `ClaudeAdapter` | Anthropic | Yes | Yes | Yes |
| `CodexAdapter` | Codex CLI | Yes | Yes | Yes |
| `AmpAdapter` | Amp (Sourcegraph) | Yes | Yes | Yes |

All adapters accept a `:permission_mode` option to control tool-call approval behavior:

```elixir
# Skip permission prompts (maps to each provider's native semantics)
{:ok, adapter} = ClaudeAdapter.start_link(permission_mode: :full_auto)
{:ok, adapter} = CodexAdapter.start_link(working_directory: ".", permission_mode: :full_auto)
{:ok, adapter} = AmpAdapter.start_link(cwd: ".", permission_mode: :dangerously_skip_permissions)
```

Modes: `:default`, `:accept_edits`, `:plan`, `:full_auto`, `:dangerously_skip_permissions`. See the [Provider Adapters](guides/provider_adapters.md) guide for the full mapping table.

All adapters also accept `:max_turns`, `:system_prompt`, and `:sdk_opts`:

```elixir
# Claude: unlimited tool-use turns (default), with system prompt and SDK passthrough
{:ok, adapter} = ClaudeAdapter.start_link(
  permission_mode: :full_auto,
  max_turns: nil,  # nil = unlimited (default). Was incorrectly hardcoded to 1 before.
  system_prompt: "You are a code reviewer.",
  sdk_opts: [verbose: true, max_budget_usd: 1.0]
)

# Codex: custom turn limit with system prompt
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: ".",
  max_turns: 25,  # nil = SDK default of 10
  system_prompt: "You are a code reviewer."  # maps to base_instructions
)
```

See the [Provider Adapters](guides/provider_adapters.md) guide for details on each option.

### Rendering Pipeline

The rendering system provides a pluggable pipeline for formatting and outputting agent session events. It separates _what_ events look like (renderers) from _where_ they go (sinks).

```elixir
alias AgentSessionManager.Rendering
alias AgentSessionManager.Rendering.Renderers.CompactRenderer
alias AgentSessionManager.Rendering.Sinks.{TTYSink, FileSink, JSONLSink}

Rendering.stream(event_stream,
  renderer: {CompactRenderer, color: true},
  sinks: [
    {TTYSink, []},
    {FileSink, path: "session.log"},
    {JSONLSink, path: "events.jsonl", mode: :full}
  ]
)
```

Built-in renderers: `CompactRenderer` (single-line token format with ANSI colors), `VerboseRenderer` (bracketed line-by-line), `PassthroughRenderer` (no-op for programmatic sinks). Built-in sinks: `TTYSink`, `FileSink`, `JSONLSink` (full and compact modes), `CallbackSink`. See the [Rendering](guides/rendering.md) guide for details.

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
| `workspace_snapshot_taken` | Workspace snapshot captured |
| `workspace_diff_computed` | Workspace diff summary computed |
| `policy_violation` | Policy violation detected |

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
# Cursor examples (live providers)
mix run examples/cursor_pagination.exs --provider claude
mix run examples/cursor_follow_stream.exs --provider codex
mix run examples/cursor_wait_follow.exs --provider amp  # long-poll (no busy polling)

# Feature 2 and 3 examples
mix run examples/session_continuity.exs --provider amp
mix run examples/workspace_snapshot.exs --provider claude

# Feature 4 and 5 examples
mix run examples/provider_routing.exs --provider codex
mix run examples/policy_enforcement.exs --provider claude

# Feature 4 v2 and 5 v2 examples (Phase 2)
mix run examples/routing_v2.exs --provider amp
mix run examples/policy_v2.exs --provider claude

# Feature 6 v2: multi-slot concurrency
mix run examples/session_concurrency.exs --provider claude

# Permission modes (full_auto, dangerously_skip_permissions, etc.)
mix run examples/permission_mode.exs --provider claude --mode full_auto

# Rendering pipeline examples
mix run examples/rendering_compact.exs --provider claude
mix run examples/rendering_verbose.exs --provider codex
mix run examples/rendering_multi_sink.exs --provider amp
mix run examples/rendering_callback.exs --provider claude

# Persistence examples (no provider needed)
mix run examples/sqlite_session_store_live.exs
mix run examples/ecto_session_store_live.exs
mix run examples/s3_artifact_store_live.exs
mix run examples/composite_store_live.exs
mix run examples/persistence_query.exs
mix run examples/persistence_maintenance.exs
mix run examples/persistence_multi_run.exs

# Persistence with local MinIO (Docker required)
MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  mix run examples/persistence_s3_minio.exs

# Persistence with live provider
mix run examples/persistence_live.exs --provider claude

# Default run-all mode executes all examples for all providers
bash examples/run_all.sh

# All examples for a single live provider
bash examples/run_all.sh --provider codex
```

See `examples/README.md` for full documentation.

## Guides

The guides cover each subsystem in depth:

- [Getting Started](guides/getting_started.md) -- Installation, first session, and core workflow
- [Live Examples](guides/live_examples.md) -- Running all live examples and validating contract surfaces
- [Architecture](guides/architecture.md) -- Ports & adapters design, module map, data flow
- [Configuration](guides/configuration.md) -- Layered config system, process-local overrides
- [Sessions and Runs](guides/sessions_and_runs.md) -- Lifecycle state machines, metadata, context
- [Session Server Runtime](guides/session_server_runtime.md) -- Per-session FIFO queueing, multi-slot concurrency, submit/await/cancel/drain, and limiter/control-ops integration
- [Session Server Subscriptions](guides/session_server_subscriptions.md) -- Durable event subscriptions with backfill, cursor replay, and filtering
- [Session Continuity](guides/session_continuity.md) -- Transcript reconstruction, continuation options, adapter replay behavior
- [Events and Streaming](guides/events_and_streaming.md) -- Event types, normalization, EventStream cursor
- [Rendering](guides/rendering.md) -- Pluggable Renderer x Sink pipeline for formatting and outputting events
- [Cursor Streaming and Migration](guides/cursor_streaming_and_migration.md) -- Sequence assignment, cursor APIs, and custom store migration
- [Workspace Snapshots](guides/workspace_snapshots.md) -- Workspace options, snapshot/diff events, metadata, and rollback scope
- [Provider Routing](guides/provider_routing.md) -- Router-as-adapter setup, capability matching, health, failover, cancel routing
- [Policy Enforcement](guides/policy_enforcement.md) -- Policy model, runtime enforcement, final result semantics, cost checks
- [Advanced Patterns](guides/advanced_patterns.md) -- Cross-feature integration: routing + policies, SessionServer + subscriptions + workspace, stickiness + continuity
- [Provider Adapters](guides/provider_adapters.md) -- Using Claude/Codex/Amp adapters, writing your own
- [Capabilities](guides/capabilities.md) -- Defining capabilities, negotiation, manifests, registry
- [Concurrency](guides/concurrency.md) -- Session/run limits, slot management, control operations
- [Telemetry and Observability](guides/telemetry_and_observability.md) -- Telemetry events, audit logging, metrics
- [Error Handling](guides/error_handling.md) -- Error taxonomy, retryable errors, provider errors
- [Testing](guides/testing.md) -- Mock adapters, in-memory store, testing patterns
- [Persistence Overview](guides/persistence_overview.md) -- Ports, adapters, and event persistence flow
- [Ecto SessionStore](guides/ecto_session_store.md) -- Production Ecto adapter for PostgreSQL and SQLite
- [SQLite with EctoSessionStore](guides/sqlite_session_store.md) -- Zero-dependency file-backed persistence via Ecto
- [S3 ArtifactStore](guides/s3_artifact_store.md) -- S3-compatible object storage for artifacts
- [CompositeSessionStore](guides/composite_store.md) -- Unified session + artifact backend
- [Event Schema Versioning](guides/event_schema_versioning.md) -- Schema evolution and versioning strategy
- [Custom Persistence Guide](guides/custom_persistence_guide.md) -- Implementing your own persistence adapters

## Documentation

Full API documentation is available at [HexDocs](https://hexdocs.pm/agent_session_manager).

## License

AgentSessionManager is released under the [MIT License](LICENSE).
