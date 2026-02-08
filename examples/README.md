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
