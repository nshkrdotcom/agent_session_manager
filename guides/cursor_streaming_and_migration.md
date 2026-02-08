# Cursor Streaming and Migration

Feature 1 introduces durable cursor-backed event streaming.

## What Changed

`SessionStore` now includes two required callbacks:

- `append_event_with_sequence/2` -- appends an event and atomically assigns a monotonic per-session `sequence_number`
- `get_latest_sequence/2` -- returns the highest assigned sequence for a session (or `0` when no events exist)

`get_events/3` also supports cursor filters:

- `after: non_neg_integer()` -- strictly greater-than sequence cursor
- `before: non_neg_integer()` -- strictly less-than sequence cursor

This is an explicit contract break for custom `SessionStore` implementations.

## Sequencing Semantics

For each `session_id`:

- Sequence numbers start at `1`
- Sequence numbers increase by exactly `1` per newly appended event
- Duplicate event IDs are idempotent and must return the originally stored event and sequence number
- Event ordering from `get_events/3` remains append order (oldest first)

## SessionManager Behavior

`SessionManager` now persists lifecycle and adapter events through sequenced appends.
Public run APIs are unchanged:

- `execute_run/4`
- `run_once/4`

For polling consumers, use:

```elixir
SessionManager.stream_session_events(store, session_id,
  after: 0,
  limit: 100,
  poll_interval_ms: 250
)
```

## Migration Checklist for Custom Stores

1. Add `append_event_with_sequence/2` callback implementation.
2. Add `get_latest_sequence/2` callback implementation.
3. Extend `get_events/3` to honor `after` and `before` cursor filters.
4. Preserve existing filter behavior (`run_id`, `type`, `since`, `limit`).
5. Preserve duplicate event ID idempotency.
6. Ensure sequence assignment and append are atomic in your store backend.

## Reference Implementation Pattern

For a process-backed store (GenServer/DB transaction), use this shape:

```elixir
def append_event_with_sequence(store, event) do
  # Atomic section:
  # 1) check duplicate event_id
  # 2) read session's latest sequence
  # 3) assign next = latest + 1
  # 4) persist event with next
  # 5) persist updated latest sequence
  # 6) return stored event
end
```

DB-backed stores should do this in a single transaction with row-level locking or equivalent concurrency control.

## Cursor Query Examples

```elixir
# Next page after cursor
{:ok, events} = SessionStore.get_events(store, session_id, after: cursor, limit: 50)

# Historical window
{:ok, events} = SessionStore.get_events(store, session_id, after: 1_000, before: 1_100)

# Resume from latest known cursor
{:ok, latest} = SessionStore.get_latest_sequence(store, session_id)
```
