# Cursor Streaming and Migration

Feature 1 introduces durable cursor-backed event streaming. Phase 2 adds
long-poll semantics and richer metadata persistence.

## What Changed (Phase 1)

`SessionStore` now includes two required callbacks:

- `append_event_with_sequence/2` -- appends an event and atomically assigns a monotonic per-session `sequence_number`
- `get_latest_sequence/2` -- returns the highest assigned sequence for a session (or `0` when no events exist)

`get_events/3` also supports cursor filters:

- `after: non_neg_integer()` -- strictly greater-than sequence cursor
- `before: non_neg_integer()` -- strictly less-than sequence cursor

This is an explicit contract break for custom `SessionStore` implementations.

## What Changed (Phase 2)

### Long-Poll Support (`wait_timeout_ms`)

`get_events/3` now accepts an optional `wait_timeout_ms` parameter:

- `wait_timeout_ms: non_neg_integer()` -- when set and the query would return
  an empty list, the store may block until matching events arrive or the
  timeout elapses

This is an **optional** optimization. Stores that do not support it simply
ignore the parameter and return immediately (existing behavior).

`InMemorySessionStore` implements long-poll by tracking "waiters" and using
`GenServer.reply/2` to respond when matching events are appended, without
blocking the GenServer loop.

`SessionManager.stream_session_events/3` now accepts `wait_timeout_ms` and
forwards it to the store, eliminating busy polling when supported.

### Adapter Event Metadata Persistence

`SessionManager.handle_adapter_event/4` now preserves:

- **Adapter-provided timestamps**: When the adapter emits a `DateTime`
  timestamp, it is stored in `Event.timestamp` instead of `DateTime.utc_now()`.
- **Adapter-provided metadata**: When the adapter emits a `metadata` map,
  it is merged into `Event.metadata`.
- **Provider identity**: `Event.metadata[:provider]` is always set to the
  adapter's provider name string.

No new event atoms are added. This is purely a data/metadata correctness
improvement.

## Sequencing Semantics

For each `session_id`:

- Sequence numbers start at `1`
- Sequence numbers increase by exactly `1` per newly appended event
- Duplicate event IDs are idempotent and must return the originally stored event and sequence number
- Event ordering from `get_events/3` remains append order (oldest first)

## SessionManager Behavior

`SessionManager` persists lifecycle and adapter events through sequenced appends.
Public run APIs are unchanged:

- `execute_run/4`
- `run_once/4`

For polling consumers, use:

```elixir
# Polling mode (default)
SessionManager.stream_session_events(store, session_id,
  after: 0,
  limit: 100,
  poll_interval_ms: 250
)

# Long-poll mode (Phase 2) — no busy polling
SessionManager.stream_session_events(store, session_id,
  after: cursor,
  limit: 100,
  wait_timeout_ms: 5_000
)
```

## Migration Checklist for Custom Stores

### Phase 1 (Required)

1. Add `append_event_with_sequence/2` callback implementation.
2. Add `get_latest_sequence/2` callback implementation.
3. Extend `get_events/3` to honor `after` and `before` cursor filters.
4. Preserve existing filter behavior (`run_id`, `type`, `since`, `limit`).
5. Preserve duplicate event ID idempotency.
6. Ensure sequence assignment and append are atomic in your store backend.

### Phase 2 (Optional)

7. Optionally support `wait_timeout_ms` in `get_events/3`. If not supported,
   ignore the option (callers fall back to sleep-based polling).

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

### Long-Poll Reference (Optional)

For GenServer-backed stores, implement long-poll using deferred replies:

```elixir
def handle_call({:get_events, session_id, opts}, from, state) do
  events = query_events(state, session_id, opts)
  wait_timeout_ms = Keyword.get(opts, :wait_timeout_ms, 0)

  if events == [] and wait_timeout_ms > 0 do
    timer_ref = Process.send_after(self(), {:waiter_timeout, from}, wait_timeout_ms)
    waiter = {from, session_id, opts, timer_ref}
    {:noreply, %{state | waiters: [waiter | state.waiters]}}
  else
    {:reply, {:ok, events}, state}
  end
end
```

When events are appended, check waiters and reply via `GenServer.reply/2`.

## Cursor Query Examples

```elixir
# Next page after cursor
{:ok, events} = SessionStore.get_events(store, session_id, after: cursor, limit: 50)

# Historical window
{:ok, events} = SessionStore.get_events(store, session_id, after: 1_000, before: 1_100)

# Resume from latest known cursor
{:ok, latest} = SessionStore.get_latest_sequence(store, session_id)

# Long-poll: block up to 5 seconds for new events
{:ok, events} = SessionStore.get_events(store, session_id,
  after: cursor, wait_timeout_ms: 5_000)
```
