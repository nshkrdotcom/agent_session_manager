# Event Schema Versioning

Every `AgentSessionManager.Core.Event` includes `schema_version`.

## Current Contract

- `Event.to_map/1` always writes `"schema_version"`.
- `Event.from_map/1` requires `"schema_version"` to be present.
- `"schema_version"` must be an integer `>= 1`.
- Missing, `nil`, or invalid values return `{:error, %Error{code: :validation_error}}`.

## Writing Events

```elixir
{:ok, event} =
  Event.new(%{
    type: :session_created,
    session_id: "ses_001"
  })

map = Event.to_map(event)
map["schema_version"]
# => 1
```

`Event.new/1` defaults to version `1` unless explicitly overridden.

## Reading Events

```elixir
{:ok, event} =
  Event.from_map(%{
    "id" => "evt_001",
    "type" => "session_created",
    "session_id" => "ses_001",
    "timestamp" => "2025-01-27T12:00:00Z",
    "schema_version" => 1
  })

event.schema_version
# => 1
```

Invalid input examples:

```elixir
# Missing schema_version
{:error, error} = Event.from_map(%{
  "id" => "evt_002",
  "type" => "run_started",
  "session_id" => "ses_001",
  "timestamp" => "2025-01-27T12:00:00Z"
})

# Non-integer schema_version
{:error, error} = Event.from_map(%{
  "id" => "evt_003",
  "type" => "run_started",
  "session_id" => "ses_001",
  "timestamp" => "2025-01-27T12:00:00Z",
  "schema_version" => "1"
})
```

## Database Storage

Store adapters persist schema version as an integer column:

```sql
schema_version INTEGER NOT NULL
```

Use a default at the database layer if needed, but serialized event payloads
must still include `schema_version` when read via `Event.from_map/1`.

## Adding New Event Fields

When extending the event schema:

1. Add the field to `Event` with a sensible default.
2. Bump the default version used for new events.
3. Update `to_map/1` and `from_map/1`.
4. Add required database migration changes.
5. Keep `from_map/1` strict about `schema_version`.

