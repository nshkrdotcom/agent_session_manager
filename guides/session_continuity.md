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
  continuation: true,
  continuation_opts: [max_messages: 100],
  adapter_opts: [timeout: 120_000]
)
```

`adapter_opts` is passed through to `ProviderAdapter.execute/4` while `SessionManager` retains orchestration responsibilities.

## Event Taxonomy

Feature 2 does not add new event types. Continuity operates through transcript reconstruction and session context injection.
