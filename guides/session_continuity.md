# Session Continuity

Feature 2 adds opt-in continuity across runs using a provider-agnostic transcript reconstructed from persisted events.

## Why It Exists

Without continuity, each `execute_run/4` call behaves like a one-shot interaction. With continuity enabled, `SessionManager` rebuilds prior context and injects it into the adapter input path.

## Transcript Model

Continuity uses `AgentSessionManager.Core.Transcript`:

- `session_id`
- `messages`
- `last_sequence`
- `last_timestamp`
- `metadata`

Each transcript message is normalized to a provider-agnostic shape:

- `role` (`:system | :user | :assistant | :tool`)
- `content`
- `tool_call_id`
- `tool_name`
- `tool_input`
- `tool_output`
- `metadata`

## Transcript Builder APIs

`AgentSessionManager.Core.TranscriptBuilder` exposes three paths:

```elixir
alias AgentSessionManager.Core.TranscriptBuilder

{:ok, transcript} = TranscriptBuilder.from_events(events, session_id: session.id)
{:ok, transcript} = TranscriptBuilder.from_store(store, session.id, limit: 500)
{:ok, updated} = TranscriptBuilder.update_from_store(store, transcript)
```

Ordering rules:

1. Prefer `sequence_number`
2. Fall back to `timestamp`
3. Use deterministic tie-breakers for stable output

Tool call ID normalization:

```elixir
tool_call_id = data[:tool_call_id] || data[:tool_use_id] || data[:call_id]
```

`tool_call_id` is now emitted canonically by all built-in adapters; the fallback fields support legacy events.

## `execute_run/4` Continuation Options

Continuity is opt-in:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: true,
  continuation_opts: [
    limit: 1_000,
    max_messages: 200
  ]
)
```

When enabled, `SessionManager` injects the transcript into:

```elixir
session.context[:transcript]
```

Adapters consume this context when available. If provider-native thread/session reuse is unavailable, transcript replay is the fallback.

### Continuation Modes (Phase 2)

The `:continuation` option accepts expanded mode values:

| Value     | Behavior |
|-----------|----------|
| `false`   | Disabled (default). No transcript injected. |
| `true`    | Alias for `:auto`. Backward compatible. |
| `:auto`   | Replay transcript from persisted events (falls back from native when unavailable). |
| `:replay` | Always replay transcript from events, even if native continuation is available. |
| `:native` | Use provider-native session continuation. Errors if the provider doesn't support it. |

```elixir
# Explicit replay mode
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :replay,
  continuation_opts: [max_messages: 200]
)

# Auto mode (same as true, uses replay as fallback)
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto
)

# Native mode (errors if unavailable)
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :native
)
```

### Token-Aware Truncation (Phase 2)

TranscriptBuilder supports character- and token-based truncation in addition to message count:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto,
  continuation_opts: [
    max_messages: 200,
    max_chars: 50_000,
    max_tokens_approx: 12_000
  ]
)
```

- `max_chars` - hard character budget for the transcript content.
- `max_tokens_approx` - approximate token budget, converted using a 4-chars-per-token heuristic.
- When both are provided, the lower effective limit wins.
- Truncation keeps the most recent messages within the budget.

### Per-Provider Continuation Handles (Phase 2)

After execution, provider session metadata (e.g., `provider_session_id`, `model`) is stored both at the top level of `session.metadata` (backward compat) and under a per-provider key:

```elixir
session.metadata[:provider_session_id]          # top-level (backward compat)
session.metadata[:provider_sessions]["claude"]  # per-provider keyed map
```

This allows sessions that interact with multiple providers to track continuation handles independently.

## `run_once/4` Support

`run_once/4` forwards continuity options to `execute_run/4`:

```elixir
{:ok, result} = SessionManager.run_once(store, adapter, input,
  continuation: true,
  continuation_opts: [max_messages: 100]
)
```

## Adapter Options Pass-Through

You can combine continuity with adapter-specific options:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto,
  continuation_opts: [max_messages: 100, max_chars: 50_000],
  adapter_opts: [timeout: 120_000]
)
```

`adapter_opts` is passed through to `ProviderAdapter.execute/4` while `SessionManager` retains orchestration responsibilities.

## Event Taxonomy

Feature 2 does not add new event types. Continuity operates through transcript reconstruction and session context injection.
