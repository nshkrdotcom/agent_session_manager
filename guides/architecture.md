# Architecture

AgentSessionManager follows a **ports and adapters** (hexagonal) architecture. The core business logic has no dependencies on external systems -- all I/O goes through well-defined interfaces (ports) with swappable implementations (adapters).

## Module Map

```
lib/agent_session_manager.ex              -- Top-level convenience delegates
lib/agent_session_manager/
  session_manager.ex                      -- Orchestration layer

  core/                                   -- Pure domain logic (no side effects)
    session.ex                            -- Session data structure & state machine
    run.ex                                -- Run data structure & lifecycle
    event.ex                              -- Event data structure & types
    normalized_event.ex                   -- Canonical event format
    event_normalizer.ex                   -- Raw -> normalized event pipeline
    event_stream.ex                       -- Cursor-based event consumption
    capability.ex                         -- Capability definition
    capability_resolver.ex                -- Capability negotiation
    manifest.ex                           -- Agent manifest (name, version, capabilities)
    registry.ex                           -- Thread-safe manifest registry
    error.ex                              -- Error taxonomy

  ports/                                  -- Interfaces (behaviours)
    provider_adapter.ex                   -- AI provider contract
    session_store.ex                      -- Storage contract

  adapters/                               -- Implementations
    claude_adapter.ex                     -- Anthropic Claude integration
    codex_adapter.ex                      -- Codex CLI integration
    in_memory_session_store.ex            -- ETS-backed store for dev/test

  concurrency/                            -- Concurrency controls
    concurrency_limiter.ex                -- Session/run slot management
    control_operations.ex                 -- Interrupt, cancel, pause, resume

  config.ex                               -- Centralized config with process-local overrides
  telemetry.ex                            -- Telemetry event emission
  audit_logger.ex                         -- Audit log persistence
```

## Design Principles

### Core Contains No Side Effects

Everything in `core/` is a pure data structure or pure function. `Session.new/1` returns a struct. `Run.update_status/2` returns a new struct. `EventNormalizer.normalize/2` transforms data. None of these modules start processes, perform I/O, or depend on external systems.

This makes the core easy to test, reason about, and reuse.

### Ports Define Contracts

The `ports/` directory contains Elixir behaviours that define the contracts between the core and the outside world:

- **`ProviderAdapter`** -- any AI provider must implement `name/1`, `capabilities/1`, `execute/4`, `cancel/2`, and `validate_config/2`
- **`SessionStore`** -- any storage backend must implement session CRUD, run CRUD, and event append/query operations

### Adapters Implement Contracts

The `adapters/` directory contains concrete implementations:

- **`ClaudeAdapter`** -- a GenServer that talks to the Anthropic API via ClaudeAgentSDK
- **`CodexAdapter`** -- a GenServer that talks to the Codex CLI via the Codex SDK
- **`InMemorySessionStore`** -- a GenServer backed by ETS tables, suitable for development and testing

### SessionManager Orchestrates

`SessionManager` is the coordination layer that ties everything together. It:

1. Creates sessions and runs using core types
2. Persists them via the `SessionStore` port
3. Checks capabilities via the `ProviderAdapter` port
4. Executes runs and handles the event flow
5. Emits telemetry for observability

## Data Flow

Here's the flow for a typical `execute_run` call:

```
SessionManager.execute_run(store, adapter, run_id)
  |
  |-- SessionStore.get_run(store, run_id)           -- fetch run from storage
  |-- SessionStore.get_session(store, session_id)   -- fetch parent session
  |-- Run.update_status(run, :running)              -- pure state transition
  |-- SessionStore.save_run(store, running_run)     -- persist updated run
  |
  |-- ProviderAdapter.execute(adapter, run, session, opts)
  |     |
  |     |-- [adapter sends request to AI provider]
  |     |-- [provider streams responses]
  |     |-- event_callback.(normalized_event)       -- for each event:
  |     |     |-- Event.new(event_data)             --   create event struct
  |     |     |-- SessionStore.append_event(event)  --   persist to store
  |     |     |-- Telemetry.emit_adapter_event()    --   emit telemetry
  |     |
  |     |-- {:ok, result}                           -- final result
  |
  |-- Run.set_output(run, result.output)            -- pure state transition
  |-- Run.update_token_usage(run, result.usage)     -- pure accumulation
  |-- SessionStore.save_run(store, final_run)       -- persist completed run
  |
  |-- {:ok, result}                                 -- returned to caller
```

## Adapter GenServer Pattern

Both `ClaudeAdapter` and `CodexAdapter` follow the same GenServer pattern:

1. The GenServer handles the public API (`execute`, `cancel`, `capabilities`)
2. Execution happens in supervised **nolink** tasks to avoid blocking the GenServer
3. Task results and `:DOWN` messages are handled for deterministic replies and cleanup
4. Cancellation signals the active task/stream and updates tracked run state

This design allows multiple runs to execute concurrently through a single adapter process, and supports cancellation without blocking.

## Thread Safety

- **Core types** are immutable structs -- inherently safe for concurrent use
- **Registry** uses immutable data structures; each operation returns a new registry
- **InMemorySessionStore** uses a GenServer for writes and ETS for concurrent reads
- **ConcurrencyLimiter** uses a GenServer to serialize slot acquire/release operations
- **Adapters** use GenServers with supervised nolink tasks for concurrent execution

## Extending the System

To add a new provider, implement the `ProviderAdapter` behaviour. To add a new storage backend (e.g., PostgreSQL), implement the `SessionStore` behaviour. The core logic and SessionManager don't change.

See [Provider Adapters](provider_adapters.md) for a detailed guide on writing adapters.
