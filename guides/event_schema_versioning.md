# Event Schema Versioning

Every `AgentSessionManager.Core.Event` struct carries a `schema_version` field that tracks the shape of the serialized event. This enables forward-compatible schema evolution -- new fields can be added to events in future library versions without breaking stores that contain older events.

## The schema_version Field

```elixir
%Event{
  id: "evt_abc123",
  type: :message_received,
  session_id: "ses_001",
  run_id: "run_001",
  data: %{content: "Hello"},
  metadata: %{},
  sequence_number: 1,
  schema_version: 1          # <-- current version
}
```

The field is an integer. The current default is `1`. It is set automatically when creating events via `Event.new/1` unless explicitly overridden.

## Why It Exists

AgentSessionManager persists events to durable storage (SQLite, Ecto/Postgres, etc.) as serialized maps. Over time, the library may add new fields to the `Event` struct -- for example, a `correlation_id` or `parent_event_id`. When that happens:

1. **New events** are written with the new `schema_version` (e.g., `2`) and include the new fields.
2. **Old events** already stored with `schema_version: 1` remain valid. They simply lack the new fields.
3. **Deserialization** uses the `schema_version` to decide which fields to expect, applying sensible defaults for anything missing.

This avoids the need for data migrations when upgrading the library.

## How It Works in Serialization

### Writing (to_map)

`Event.to_map/1` always includes the `schema_version` in the serialized output:

```elixir
{:ok, event} = Event.new(%{
  type: :session_created,
  session_id: "ses_001"
})

map = Event.to_map(event)
# => %{
#   "id" => "evt_...",
#   "type" => "session_created",
#   "timestamp" => "2025-01-27T12:00:00Z",
#   "session_id" => "ses_001",
#   "run_id" => nil,
#   "data" => %{},
#   "metadata" => %{},
#   "sequence_number" => nil,
#   "schema_version" => 1
# }
```

### Reading (from_map)

`Event.from_map/1` reads the `schema_version` from the stored map. If the field is absent (e.g., events written before versioning was added), it defaults to `1`:

```elixir
# Map with explicit version
{:ok, event} = Event.from_map(%{
  "id" => "evt_001",
  "type" => "session_created",
  "session_id" => "ses_001",
  "timestamp" => "2025-01-27T12:00:00Z",
  "schema_version" => 1
})
event.schema_version  # => 1

# Map without version (legacy data)
{:ok, event} = Event.from_map(%{
  "id" => "evt_002",
  "type" => "run_started",
  "session_id" => "ses_001",
  "timestamp" => "2025-01-27T12:00:00Z"
})
event.schema_version  # => 1  (nil treated as 1)
```

### Database Storage

The SQLite and Ecto adapters persist `schema_version` as an integer column with a `DEFAULT 1`:

```sql
CREATE TABLE IF NOT EXISTS asm_events (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  session_id TEXT NOT NULL,
  run_id TEXT NULL,
  sequence_number INTEGER NOT NULL,
  data TEXT DEFAULT '{}',
  metadata TEXT DEFAULT '{}',
  schema_version INTEGER NOT NULL DEFAULT 1
);
```

This means the column is always populated, even for rows inserted by older code that did not set it explicitly.

## Backward Compatibility

The versioning system is designed so that no data migration is needed when upgrading:

- **nil treated as 1**: Both `Event.from_map/1` and the store adapters treat a missing or `nil` `schema_version` as version `1`. Events written before the field existed are seamlessly interpreted as v1.
- **Unknown fields are ignored**: `Event.from_map/1` only reads known fields from the map. Extra keys from a future version are silently dropped, so a newer writer and an older reader can coexist.
- **Defaults for missing fields**: When a new version adds a field, `from_map/1` applies a default if the field is absent in the stored map.

## Guidelines for Adding New Event Fields

If you are extending the library and need to add a field to the `Event` struct, follow these steps:

1. **Add the field to the struct** with a default value (e.g., `nil` or `%{}`):

    ```elixir
    defstruct [
      :id,
      :type,
      :timestamp,
      :session_id,
      :run_id,
      :sequence_number,
      :correlation_id,       # new field
      data: %{},
      metadata: %{},
      schema_version: 2      # bump default
    ]
    ```

2. **Bump the default `schema_version`** in the struct definition and in `Event.new/1`.

3. **Update `to_map/1`** to include the new field in the serialized output.

4. **Update `from_map/1`** to read the new field with a fallback default:

    ```elixir
    correlation_id = case map["schema_version"] || 1 do
      v when v >= 2 -> map["correlation_id"]
      _ -> nil
    end
    ```

5. **Update the database schema** in the SQLite bootstrapper and Ecto migration to add the new column with a default:

    ```sql
    ALTER TABLE asm_events ADD COLUMN correlation_id TEXT DEFAULT NULL;
    ```

6. **Do not modify existing stored events.** The point of versioning is that old rows remain valid as-is.

## Explicitly Setting the Version

In most cases you should not set `schema_version` manually. `Event.new/1` applies the current default. However, if you are constructing events for testing or migration purposes, you can override it:

```elixir
{:ok, event} = Event.new(%{
  type: :session_created,
  session_id: "ses_001",
  schema_version: 2
})
```

## Schema Version 2 (v0.7.0)

Version 2 added the following fields to the Event struct:

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `provider` | `String.t() \| nil` | `nil` | Name of the provider that generated the event |
| `correlation_id` | `String.t() \| nil` | `nil` | Correlation ID for tracing across services |

These fields are populated automatically by the EventPipeline when events are
processed through `SessionManager`. Events written by older code (schema_version 1)
will have `nil` for both fields when read back.

The V2 database migration adds the corresponding columns:

```sql
ALTER TABLE asm_events ADD COLUMN provider TEXT DEFAULT NULL;
ALTER TABLE asm_events ADD COLUMN correlation_id TEXT DEFAULT NULL;
```

Run `MigrationV2.up()` to apply these changes. See the
[EctoSessionStore guide](ecto_session_store.md) for migration instructions.

## Notes and Caveats

- **Version is per-event, not per-store.** A single event store can contain events with mixed schema versions. This is expected and handled correctly by `from_map/1`.

- **Schema version only covers the Event struct.** Session and Run structs do not currently carry a schema version. If those structs need evolution in the future, a similar mechanism can be added.

- **Monotonically increasing.** Schema versions only go up. A version `2` event always has a superset of version `1` fields. There is no concept of removing fields in a new version.

- **Read tolerance.** Code reading events should always handle missing optional fields gracefully, regardless of schema version. This is a defense-in-depth measure beyond the version-based branching in `from_map/1`.
