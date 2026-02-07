# Events and Streaming

Events are the foundation of observability in AgentSessionManager. Every significant action -- session creation, message streaming, tool calls, errors -- produces an immutable event that is persisted and can be consumed in real time.

## Event Types

Events are grouped into categories:

### Session Lifecycle
| Type | When |
|------|------|
| `:session_created` | A new session was created |
| `:session_started` | Session transitioned to active |
| `:session_paused` | Session was paused |
| `:session_resumed` | Session resumed from pause |
| `:session_completed` | Session completed successfully |
| `:session_failed` | Session failed with error |
| `:session_cancelled` | Session was cancelled |

### Run Lifecycle
| Type | When |
|------|------|
| `:run_started` | A run began execution |
| `:run_completed` | A run completed successfully |
| `:run_failed` | A run failed with error |
| `:run_cancelled` | A run was cancelled |
| `:run_timeout` | A run timed out |

### Messages
| Type | When |
|------|------|
| `:message_sent` | A message was sent to the agent |
| `:message_received` | A complete message was received from the agent |
| `:message_streamed` | A streaming chunk was received |

### Tool Calls
| Type | When |
|------|------|
| `:tool_call_started` | A tool call began |
| `:tool_call_completed` | A tool call completed |
| `:tool_call_failed` | A tool call failed |

### Errors and Usage
| Type | When |
|------|------|
| `:error_occurred` | An error happened during execution |
| `:error_recovered` | Recovery from an error |
| `:token_usage_updated` | Token counts were updated |
| `:turn_completed` | A conversation turn completed |

## Creating Events

```elixir
alias AgentSessionManager.Core.Event

{:ok, event} = Event.new(%{
  type: :message_received,
  session_id: session.id,
  run_id: run.id,
  data: %{content: "Hello!", role: "assistant"},
  metadata: %{model: "claude-haiku-4-5-20251001"}
})

event.id         # => "evt_a1b2c3..."  (auto-generated)
event.timestamp  # => ~U[2025-01-27 12:00:00Z]
```

Events are immutable -- once created, they cannot be modified.

## Persisting Events

Events are stored via the `SessionStore` port using append-only semantics:

```elixir
alias AgentSessionManager.Ports.SessionStore

:ok = SessionStore.append_event(store, event)
```

Appending is idempotent: storing the same event ID twice doesn't create a duplicate.

## Querying Events

```elixir
# All events for a session
{:ok, events} = SessionStore.get_events(store, session.id)

# Filter by run
{:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)

# Filter by type
{:ok, events} = SessionStore.get_events(store, session.id, type: :message_received)

# Filter by time
{:ok, events} = SessionStore.get_events(store, session.id, since: one_hour_ago)

# Combine filters
{:ok, events} = SessionStore.get_events(store, session.id,
  run_id: run.id,
  type: :tool_call_completed,
  limit: 10
)
```

Events are always returned in append order (oldest first).

## Event Normalization

When working with raw provider events (e.g., from webhook payloads), the `EventNormalizer` transforms them into the canonical `NormalizedEvent` format:

```elixir
alias AgentSessionManager.Core.EventNormalizer

raw_event = %{
  "type" => "assistant_message",
  "content" => "Hello!",
  "model" => "claude-haiku-4-5-20251001"
}

context = %{
  session_id: session.id,
  run_id: run.id,
  provider: :anthropic
}

{:ok, normalized} = EventNormalizer.normalize(raw_event, context)
normalized.type  # => :message_received  (mapped from "assistant_message")
```

The normalizer handles type mapping, sequence numbering, and metadata extraction. It maps common provider patterns to canonical types:

- `"assistant_message"`, `"ai_message"`, `"assistant"` -> `:message_received`
- `"delta"`, `"content_block_delta"`, `"stream"` -> `:message_streamed`
- `"tool_use"`, `"tool_call"`, `"function_call"` -> `:tool_call_started`
- `"error"`, `"exception"` -> `:error_occurred`

### SessionManager Ingest Normalization

`SessionManager.execute_run/4` applies event-type normalization on adapter callback events before persistence.
This means alias event types such as `"run_start"`, `"run_end"`, and `"delta"` are stored as canonical
`Event.type` atoms (`:run_started`, `:run_completed`, `:message_streamed`).

### Batch Normalization

```elixir
{:ok, events} = EventNormalizer.normalize_batch(raw_events, context)
```

Events in a batch get sequential `sequence_number` values automatically.

### Sorting and Filtering

```elixir
sorted = EventNormalizer.sort_events(events)           # by sequence, then timestamp, then id
filtered = EventNormalizer.filter_by_type(events, :message_streamed)
filtered = EventNormalizer.filter_by_run(events, run.id)
```

## EventStream: Cursor-Based Consumption

The `EventStream` module provides a cursor-based mechanism for consuming events incrementally -- useful for building streaming UIs or processing events in order.

```elixir
alias AgentSessionManager.Core.EventStream

# Create a stream for a specific run
{:ok, stream} = EventStream.new(%{session_id: session.id, run_id: run.id})

# Push events as they arrive
{:ok, stream} = EventStream.push(stream, event1)
{:ok, stream} = EventStream.push(stream, event2)
{:ok, stream} = EventStream.push_batch(stream, [event3, event4])

# Peek at events without advancing the cursor
events = EventStream.peek(stream, 3)

# Take events and advance the cursor
{:ok, events, stream} = EventStream.take(stream, 2)

# Check counts
EventStream.count(stream)      # total events in buffer
EventStream.remaining(stream)  # unread events from cursor

# Get all events (sorted by sequence number)
all = EventStream.get_events(stream)
all = EventStream.get_events(stream, from_cursor: true, type: :message_streamed)
```

### Buffer Management

EventStream has a configurable buffer size (default: 1000). When the buffer is full, older events are evicted to make room:

```elixir
{:ok, stream} = EventStream.new(%{
  session_id: session.id,
  run_id: run.id,
  buffer_size: 500
})
```

### Context Validation

Events pushed to a stream must match its `session_id` and `run_id`. Mismatched events are rejected:

```elixir
{:error, %Error{code: :session_mismatch}} =
  EventStream.push(stream, event_from_different_session)
```

### Closing a Stream

```elixir
{:ok, stream} = EventStream.close(stream)
EventStream.closed?(stream)  # => true

# Closed streams reject new events
{:error, _} = EventStream.push(stream, event)
```

## Real-Time Event Handling

When executing runs through an adapter, you provide an event callback to handle events as they arrive:

```elixir
callback = fn event ->
  case event.type do
    :message_streamed ->
      # Stream content to the user in real time
      IO.write(event.data.delta)

    :tool_call_started ->
      Logger.info("Tool called: #{event.data.tool_name}")

    :token_usage_updated ->
      Logger.debug("Tokens: #{event.data.input_tokens} in, #{event.data.output_tokens} out")

    :run_completed ->
      IO.puts("\n[Complete]")

    :error_occurred ->
      Logger.error("Error: #{event.data.error_message}")

    _ ->
      :ok
  end
end

{:ok, result} = adapter_module.execute(adapter, run, session, event_callback: callback)
```

The adapter normalizes provider-specific events before invoking your callback, so you always work with the canonical event types regardless of the provider.
