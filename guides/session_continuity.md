# Session Continuity

Session continuity is opt-in per run. When enabled, `SessionManager` rebuilds a
provider-agnostic transcript from persisted events and injects it into
`session.context[:transcript]` before adapter execution.

## Transcript Model

Continuity uses `AgentSessionManager.Core.Transcript`:

- `session_id`
- `messages`
- `last_sequence`
- `last_timestamp`
- `metadata`

Each transcript message uses canonical fields:

- `role` (`:system | :user | :assistant | :tool`)
- `content`
- `tool_call_id`
- `tool_name`
- `tool_input`
- `tool_output`
- `metadata`

## Transcript Builder APIs

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

## `execute_run/4` Continuation Options

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto,
  continuation_opts: [
    limit: 1_000,
    max_messages: 200
  ]
)
```

## Continuation Modes

| Value | Behavior |
|---|---|
| `false` | Disabled (default). No transcript injected. |
| `:auto` | Replay transcript from persisted events. |
| `:replay` | Always replay transcript from persisted events. |
| `:native` | Request provider-native continuation. Returns a validation error when unavailable. |

```elixir
# Explicit replay mode
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :replay,
  continuation_opts: [max_messages: 200]
)

# Auto mode
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto
)
```

## Token-Aware Truncation

TranscriptBuilder supports character- and token-based truncation:

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

- `max_chars` - hard character budget for transcript content.
- `max_tokens_approx` - approximate token budget using a 4-chars-per-token heuristic.
- When both are set, the lower effective limit wins.
- Truncation keeps the most recent messages within budget.

## Provider Session Metadata

Provider session metadata is stored under `session.metadata[:provider_sessions]`
as a per-provider map:

```elixir
session.metadata[:provider_sessions]["claude"]
# => %{provider_session_id: "sess_...", model: "claude-haiku-4-5-20251001"}
```

This supports multi-provider sessions without duplicating top-level metadata keys.

## `run_once/4` Support

`run_once/4` forwards continuity options to `execute_run/4`:

```elixir
{:ok, result} = SessionManager.run_once(store, adapter, input,
  continuation: :auto,
  continuation_opts: [max_messages: 100]
)
```

## Adapter Options Pass-Through

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  continuation: :auto,
  continuation_opts: [max_messages: 100, max_chars: 50_000],
  adapter_opts: [timeout: 120_000]
)
```

`adapter_opts` is forwarded to `ProviderAdapter.execute/4` while
`SessionManager` handles orchestration.

