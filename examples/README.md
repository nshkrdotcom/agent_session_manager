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

## Session Continuity and Workspace Examples

These examples demonstrate Feature 2 and Feature 3 using live provider execution.

### `session_continuity.exs` -- Session Continuity (Feature 2)

- Runs two sequential turns in a single session
- Executes turn 2 with `continuation: true`
- Reconstructs and prints transcript context from persisted events

```bash
mix run examples/session_continuity.exs --provider claude
mix run examples/session_continuity.exs --provider codex
mix run examples/session_continuity.exs --provider amp
```

### `workspace_snapshot.exs` -- Workspace Snapshot + Diff + Rollback (Feature 3)

- Creates a temporary git workspace and enables workspace instrumentation
- Prints emitted workspace events (`:workspace_snapshot_taken`, `:workspace_diff_computed`)
- Prints compact diff summary and patch presence
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
