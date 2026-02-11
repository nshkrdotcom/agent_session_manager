# Examples

This directory contains runnable examples for AgentSessionManager.

All examples use real modules and real provider adapters (no mocks/fakes/stubs).

## Cursor Event Streaming Examples

These examples demonstrate Feature 1 using live provider execution plus durable store cursors.

### `cursor_pagination.exs` -- Cursor Pagination (Live Provider)

- Runs real provider executions via `SessionManager`
- Reads persisted events with `SessionStore.get_events/3` using `after`, `before`, `limit`
- Verifies monotonic sequence assignment from `append_event_with_sequence/2`
- Reads `get_latest_sequence/2`

```bash
mix run examples/cursor_pagination.exs --provider claude
mix run examples/cursor_pagination.exs --provider codex
mix run examples/cursor_pagination.exs --provider amp
```

### `cursor_follow_stream.exs` -- Cursor Follow Stream (Live Provider)

- Captures a starting cursor with `get_latest_sequence/2`
- Starts `SessionManager.stream_session_events/3` from `after: cursor`
- Executes a real run and streams newly persisted events
- Verifies streamed event sequence numbers are monotonic and after the cursor

```bash
mix run examples/cursor_follow_stream.exs --provider claude
mix run examples/cursor_follow_stream.exs --provider codex
mix run examples/cursor_follow_stream.exs --provider amp
```

### `cursor_wait_follow.exs` -- Cursor Wait Follow (Long-Poll, Live Provider)

- Demonstrates `wait_timeout_ms` long-poll mode (Phase 2 Feature 1)
- Uses `SessionManager.stream_session_events/3` with `wait_timeout_ms: 30_000`
- The store blocks until matching events arrive instead of busy polling
- Prints adapter event metadata including `provider` name and timestamps
- Shows cursor resumption from the last received sequence number

```bash
mix run examples/cursor_wait_follow.exs --provider claude
mix run examples/cursor_wait_follow.exs --provider codex
mix run examples/cursor_wait_follow.exs --provider amp
```

## Session Continuity and Workspace Examples

These examples demonstrate Feature 2 and Feature 3 using live provider execution.

### `session_continuity.exs` -- Session Continuity (Feature 2)

- Runs two sequential turns in a single session
- Executes turn 2 with `continuation: :auto` (Phase 2 mode)
- Uses token-aware truncation via `max_tokens_approx: 4_000`
- Reconstructs and prints transcript context from persisted events

```bash
mix run examples/session_continuity.exs --provider claude
mix run examples/session_continuity.exs --provider codex
mix run examples/session_continuity.exs --provider amp
```

### `workspace_snapshot.exs` -- Workspace Snapshot + Diff + Rollback (Feature 3)

- Creates a temporary git workspace and enables workspace instrumentation
- Demonstrates untracked file capture (Phase 2: git snapshots include untracked files)
- Prints emitted workspace events (`:workspace_snapshot_taken`, `:workspace_diff_computed`)
- Prints compact diff summary, patch presence, and `includes_untracked` metadata
- Demonstrates git rollback-on-failure behavior (`rollback_on_failure: true`)

```bash
mix run examples/workspace_snapshot.exs --provider claude
mix run examples/workspace_snapshot.exs --provider codex
mix run examples/workspace_snapshot.exs --provider amp
```

## Routing and Policy Examples

These examples demonstrate Feature 4 and Feature 5 using live provider execution.

### `provider_routing.exs` -- Provider Routing (Feature 4)

- Configures `ProviderRouter` as a normal `ProviderAdapter`
- Demonstrates capability-driven selection using named capability requirements
- Demonstrates retryable failover by forcing preferred-provider unavailability
- Prints routing metadata (`routed_provider`, `routing_attempt`, `failover_from`, `failover_reason`)

```bash
mix run examples/provider_routing.exs --provider claude
mix run examples/provider_routing.exs --provider codex
mix run examples/provider_routing.exs --provider amp
```

### `policy_enforcement.exs` -- Policy Enforcement (Feature 5)

- Runs two executions with real providers:
  - cancel mode (`on_violation: :cancel`)
  - warn mode (`on_violation: :warn`)
- Emits and verifies `:policy_violation` events
- Demonstrates final result semantics (cancel returns policy error, warn preserves success with metadata)

```bash
mix run examples/policy_enforcement.exs --provider claude
mix run examples/policy_enforcement.exs --provider codex
mix run examples/policy_enforcement.exs --provider amp
```

## Routing and Policy v2 Examples

These examples demonstrate Phase 2 enhancements to Feature 4 and Feature 5.

### `routing_v2.exs` -- Provider Routing v2 (Phase 2)

- Demonstrates weighted routing with `strategy: :weighted` and custom `weights` map
- Demonstrates session stickiness across two runs using `sticky_session_id`
- Prints routing metadata (`routed_provider`, `routing_candidates`)

```bash
mix run examples/routing_v2.exs --provider claude
mix run examples/routing_v2.exs --provider codex
mix run examples/routing_v2.exs --provider amp
```

### `policy_v2.exs` -- Policy Enforcement v2 (Phase 2)

- Demonstrates policy stacking via `policies: [org_policy, team_policy]` with deterministic merge
- Demonstrates provider-side enforcement where supported, with reactive fallback
- Shows merged policy semantics: tool rules concatenated, strictest `on_violation` wins

```bash
mix run examples/policy_v2.exs --provider claude
mix run examples/policy_v2.exs --provider codex
mix run examples/policy_v2.exs --provider amp
```

### `approval_gates.exs` -- Approval Gates / Human-in-the-Loop (Section 4.5)

- Demonstrates `on_violation: :request_approval` policy action
- Shows `:tool_approval_requested` event emission (does NOT cancel the run)
- Demonstrates `cancel_for_approval/4` helper for the cancel-and-resume pattern
- Shows policy stacking with the new strictness ordering: `:cancel` > `:request_approval` > `:warn`

```bash
mix run examples/approval_gates.exs --provider claude
mix run examples/approval_gates.exs --provider codex
mix run examples/approval_gates.exs --provider amp
```

## Session Server Runtime Examples

These examples demonstrate Feature 6 using live provider execution.

### `session_runtime.exs` -- Session Runtime (Feature 6)

- Starts a `SessionServer` per session
- Submits multiple runs quickly
- Awaits results to demonstrate strict sequential FIFO execution (MVP)

```bash
mix run examples/session_runtime.exs --provider claude
mix run examples/session_runtime.exs --provider codex
mix run examples/session_runtime.exs --provider amp
```

### `session_subscription.exs` -- Session Subscriptions (Feature 6)

- Subscribes to stored events via `SessionServer.subscribe/2`
- Prints `{:session_event, session_id, %Core.Event{}}` messages as runs execute
- Uses `type:` filtering to keep output readable

```bash
mix run examples/session_subscription.exs --provider claude
mix run examples/session_subscription.exs --provider codex
mix run examples/session_subscription.exs --provider amp
```

### `session_limiter.exs` -- Session Limiter Integration (Feature 6)

- Starts a real `ConcurrencyLimiter`
- Configures `SessionServer` with `limiter:`
- Prints limiter status near run start and after completion (acquire/release)

```bash
mix run examples/session_limiter.exs --provider claude
mix run examples/session_limiter.exs --provider codex
mix run examples/session_limiter.exs --provider amp
```

### `session_concurrency.exs` -- Multi-Slot Concurrency (Feature 6 v2)

- Starts a `SessionServer` with `max_concurrent_runs: 2`
- Submits 4 runs and shows that up to 2 execute in parallel
- Remaining runs are queued and drained as slots free up
- Demonstrates `drain/2` waiting for all runs to complete
- Prints status showing in-flight and queued counts

```bash
mix run examples/session_concurrency.exs --provider claude
mix run examples/session_concurrency.exs --provider codex
mix run examples/session_concurrency.exs --provider amp
```

## Permission Mode Example

### `permission_mode.exs` -- Normalized Permission Modes

- Starts an adapter with a configurable `permission_mode`
- Demonstrates the normalized mode being passed through to the provider SDK
- Supports all five modes: `:default`, `:accept_edits`, `:plan`, `:full_auto`, `:dangerously_skip_permissions`
- Each provider maps the mode to its native semantics (Claude `permission_mode`, Codex `full_auto`/`dangerously_bypass`, Amp `dangerously_allow_all`)

```bash
mix run examples/permission_mode.exs --provider claude
mix run examples/permission_mode.exs --provider codex
mix run examples/permission_mode.exs --provider amp

# With a specific mode:
mix run examples/permission_mode.exs --provider claude --mode dangerously_skip_permissions
```

## StreamSession Example

### `stream_session.exs` -- StreamSession One-Shot Lifecycle (Live Provider)

- Demonstrates `StreamSession.start/1` replacing ~35 lines of hand-rolled stream boilerplate with a single call
- Exercises two output modes:
  - **rendering**: pipes the event stream through CompactRenderer + TTYSink
  - **raw**: consumes events directly, prints streaming text and event summary
- StreamSession automatically manages store creation, adapter lifecycle, task launch, and cleanup
- Shows the idempotent `close_fun` for resource release

```bash
mix run examples/stream_session.exs --provider claude
mix run examples/stream_session.exs --provider codex --mode raw
mix run examples/stream_session.exs --provider amp --no-color
```

## Rendering Pipeline Examples

These examples demonstrate the Rendering system (Renderer x Sink architecture) using live provider execution.

### `rendering_compact.exs` -- CompactRenderer (Live Provider)

- Runs a real provider session and renders the event stream using CompactRenderer
- Demonstrates compact token format: `r+` (run start), `r-` (run end), `t+`/`t-` (tool), `>>` (text stream), `tk:` (usage)
- Supports `--no-color` flag to disable ANSI coloring
- Uses TTYSink for terminal output

```bash
mix run examples/rendering_compact.exs --provider claude
mix run examples/rendering_compact.exs --provider codex --no-color
mix run examples/rendering_compact.exs --provider amp
```

### `rendering_verbose.exs` -- VerboseRenderer (Live Provider)

- Runs a real provider session and renders using VerboseRenderer
- Demonstrates bracketed line-by-line format: `[run_started]`, `[tool_call_started]`, etc.
- Shows inline text streaming with automatic line breaks before structured events
- Uses TTYSink for terminal output

```bash
mix run examples/rendering_verbose.exs --provider claude
mix run examples/rendering_verbose.exs --provider codex
mix run examples/rendering_verbose.exs --provider amp
```

### `rendering_multi_sink.exs` -- Multi-Sink Pipeline (Live Provider)

- Runs a real provider session through all four sink types simultaneously
- **TTYSink**: colored terminal output
- **FileSink**: ANSI-stripped plain-text log file (uses `:io` option for pre-opened file with header)
- **JSONLSink**: both full and compact modes side-by-side in separate files
- **CallbackSink**: programmatic event counting
- Prints log file contents and first few JSONL lines after completion
- Supports `--mode compact|verbose` flag

```bash
mix run examples/rendering_multi_sink.exs --provider claude
mix run examples/rendering_multi_sink.exs --provider codex --mode verbose
mix run examples/rendering_multi_sink.exs --provider amp
```

### `rendering_callback.exs` -- PassthroughRenderer + CallbackSink (Live Provider)

- Runs a real provider session with PassthroughRenderer (no terminal rendering)
- All events processed programmatically via CallbackSink
- Aggregates event statistics: total events, text bytes, tools used, model, stop reason
- Captures full response text and prints it after completion
- Demonstrates using the rendering pipeline as a programmable event processor

```bash
mix run examples/rendering_callback.exs --provider claude
mix run examples/rendering_callback.exs --provider codex
mix run examples/rendering_callback.exs --provider amp
```

## Other Live Provider Examples

### `oneshot.exs` -- One-Shot Execution

```bash
mix run examples/oneshot.exs --provider claude
mix run examples/oneshot.exs --provider codex
mix run examples/oneshot.exs --provider amp
```

### `live_session.exs` -- Full Lifecycle

```bash
mix run examples/live_session.exs --provider claude
mix run examples/live_session.exs --provider codex
mix run examples/live_session.exs --provider amp
```

### `common_surface.exs` -- Provider-Agnostic Session Flow

```bash
mix run examples/common_surface.exs --provider claude
mix run examples/common_surface.exs --provider codex
mix run examples/common_surface.exs --provider amp
```

### `contract_surface_live.exs` -- Runtime Contract Checks

```bash
mix run examples/contract_surface_live.exs --provider claude
mix run examples/contract_surface_live.exs --provider codex
mix run examples/contract_surface_live.exs --provider amp
```

### Provider-Specific SDK Examples

```bash
mix run examples/claude_direct.exs
mix run examples/codex_direct.exs
mix run examples/amp_direct.exs
```

## Persistence Adapter Examples

These examples demonstrate the persistence adapters. They run locally without external services.

### `sqlite_session_store_live.exs` -- SQLite via Ecto SessionStore

- Creates a SQLite database, migrates schema, and saves sessions/events
- Demonstrates atomic sequence assignment and cursor queries
- Shows data survives store restart

```bash
mix run examples/sqlite_session_store_live.exs
```

### `ecto_session_store_live.exs` -- Ecto SessionStore

- Uses an Ecto Repo backed by SQLite
- Demonstrates all session, run, and event operations
- Shows the same SessionStore contract works with Ecto

```bash
mix run examples/ecto_session_store_live.exs
```

### `s3_artifact_store_live.exs` -- S3 ArtifactStore

- Uses an in-memory mock S3 client (no AWS credentials needed)
- Demonstrates put/get/delete lifecycle
- Shows not-found handling and idempotent deletes

```bash
mix run examples/s3_artifact_store_live.exs
```

### `composite_store_live.exs` -- CompositeSessionStore

- Combines Ecto/SQLite (sessions) with FileArtifactStore (artifacts)
- Shows session and artifact operations through a single composite store
- Demonstrates the unified interface

```bash
mix run examples/composite_store_live.exs
```

## Persistence Query, Maintenance, and Multi-Run Examples

These examples demonstrate the persistence query, maintenance, and multi-provider capabilities.
They run locally with SQLite (no external services needed).

### `persistence_query.exs` -- QueryAPI Demo

- Seeds sessions with multiple providers (Claude, Codex, Amp)
- Demonstrates cross-session search, filtering by agent, status, and provider
- Shows usage summaries, session stats, event search, and export
- Demonstrates cursor-based pagination

```bash
mix run examples/persistence_query.exs
```

### `persistence_maintenance.exs` -- Retention and Maintenance

- Creates sessions with varied ages and statuses
- Executes configurable retention policy (soft-delete, event pruning)
- Demonstrates health check for data integrity
- Shows hard-delete of expired sessions

```bash
mix run examples/persistence_maintenance.exs
```

### `persistence_multi_run.exs` -- Multi-Provider Session

- Creates a single session with runs from 3 different providers
- Demonstrates cross-provider QueryAPI aggregation and usage breakdown
- Shows per-provider event grouping and sequence integrity

```bash
mix run examples/persistence_multi_run.exs
```

### `persistence_live.exs` -- Live Provider + Persistence

- Runs a real provider SDK with EctoSessionStore persistence
- Events flow through EventPipeline into SQLite
- Verifies persisted sessions, runs, events, and sequence integrity

```bash
mix run examples/persistence_live.exs --provider claude
mix run examples/persistence_live.exs --provider codex
mix run examples/persistence_live.exs --provider amp
```

### `persistence_s3_minio.exs` -- S3 Artifacts with MinIO

- Uses S3ArtifactStore with a real MinIO instance (Docker)
- Demonstrates put/get/delete with real S3-compatible storage
- Requires Docker: see example header for setup instructions

```bash
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"

MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  mix run examples/persistence_s3_minio.exs
```

## Run All Examples

```bash
# Default: all examples across all providers (claude, codex, amp)
bash examples/run_all.sh

# Single provider
bash examples/run_all.sh --provider codex
```

Use `bash examples/run_all.sh --help` for all options.

## Provider Authentication

- Claude: `claude login` or set `ANTHROPIC_API_KEY`
- Codex: `codex login` or set `CODEX_API_KEY`
- Amp: `amp login` or set `AMP_API_KEY`
