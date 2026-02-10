# SQLiteSessionStore

`AgentSessionManager.Adapters.SQLiteSessionStore` is a file-backed session store
that persists sessions, runs, and events in a local SQLite database. It is a
good fit for CLI tools, desktop applications, and single-node deployments where
you need durable storage without an external database server.

## Prerequisites

Add the `ecto_sqlite3` dependency to your `mix.exs`. The adapter uses the
bundled `exqlite` library (a transitive dependency of `ecto_sqlite3`) directly
for raw SQLite access:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"},
    {:ecto_sqlite3, "~> 0.17"}
  ]
end
```

No Ecto Repo is needed -- the adapter opens the SQLite file directly through
`Exqlite.Sqlite3`.

## Configuration

Start the store with a `:path` to the database file. The adapter creates the
file and any parent directories automatically.

```elixir
alias AgentSessionManager.Adapters.SQLiteSessionStore

# Basic usage
{:ok, store} = SQLiteSessionStore.start_link(path: "/tmp/sessions.db")

# With a registered name
{:ok, store} = SQLiteSessionStore.start_link(
  path: "/var/data/sessions.db",
  name: :session_store
)
```

### Options

| Option  | Required | Description |
|---------|----------|-------------|
| `:path` | Yes | Path to the SQLite database file |
| `:name` | No  | GenServer name for registration |

### Supervision Tree

```elixir
children = [
  {SQLiteSessionStore, path: "priv/sessions.db", name: :session_store}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## WAL Mode and Pragmas

On startup the adapter configures SQLite for optimal performance:

| Pragma | Value | Purpose |
|--------|-------|---------|
| `journal_mode` | `WAL` | Allows concurrent reads during writes |
| `synchronous` | `NORMAL` | Balances durability and speed |
| `foreign_keys` | `ON` | Enforces referential integrity |
| `busy_timeout` | `5000` | Waits up to 5 seconds on lock contention |

WAL (Write-Ahead Logging) mode means readers never block writers and writers
never block readers, which is important because the GenServer serializes writes
while reads may come from other callers.

## Schema

The adapter bootstraps four tables on first connection. You do not need to run
any migrations.

### `asm_sessions`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT (PK) | Session identifier |
| `agent_id` | TEXT | Agent type/config identifier |
| `status` | TEXT | Atom stored as string (`"active"`, `"pending"`, ...) |
| `parent_session_id` | TEXT | Nullable. For hierarchical sessions |
| `metadata` | TEXT | JSON-encoded map |
| `context` | TEXT | JSON-encoded map |
| `tags` | TEXT | JSON-encoded list |
| `created_at` | TEXT | ISO 8601 datetime |
| `updated_at` | TEXT | ISO 8601 datetime |

### `asm_runs`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT (PK) | Run identifier |
| `session_id` | TEXT | Parent session |
| `status` | TEXT | Atom as string |
| `input` | TEXT | Nullable JSON |
| `output` | TEXT | Nullable JSON |
| `error` | TEXT | Nullable JSON |
| `metadata` | TEXT | JSON-encoded map |
| `turn_count` | INTEGER | Default 0 |
| `token_usage` | TEXT | JSON-encoded map |
| `started_at` | TEXT | ISO 8601 datetime |
| `ended_at` | TEXT | Nullable ISO 8601 datetime |

### `asm_events`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT (PK) | Event identifier |
| `type` | TEXT | Atom as string |
| `timestamp` | TEXT | ISO 8601 datetime |
| `session_id` | TEXT | Parent session |
| `run_id` | TEXT | Nullable. Parent run |
| `sequence_number` | INTEGER | Per-session monotonic sequence |
| `data` | TEXT | JSON-encoded map |
| `metadata` | TEXT | JSON-encoded map |
| `schema_version` | INTEGER | Default 1 |

A unique index on `(session_id, sequence_number)` guarantees ordering.

### `asm_session_sequences`

| Column | Type | Notes |
|--------|------|-------|
| `session_id` | TEXT (PK) | Session identifier |
| `last_sequence` | INTEGER | Last assigned sequence number |
| `updated_at` | TEXT | ISO 8601 datetime |

## Atomic Sequence Assignment

When appending an event with `append_event/2` or `append_event_with_sequence/2`,
the adapter wraps the operation in a `BEGIN IMMEDIATE` transaction:

1. Ensure a row exists in `asm_session_sequences` for the session.
2. Read the current `last_sequence` value.
3. Insert the event with `sequence_number = last_sequence + 1`.
4. Update `last_sequence` to the new value.
5. Commit.

`BEGIN IMMEDIATE` acquires a reserved lock immediately, preventing concurrent
writers from interleaving sequence assignments. Duplicate event IDs are handled
idempotently -- the existing event is returned without modification.

## Usage Examples

```elixir
alias AgentSessionManager.Adapters.SQLiteSessionStore
alias AgentSessionManager.Ports.SessionStore
alias AgentSessionManager.Core.{Session, Run, Event}

# Start the store
{:ok, store} = SQLiteSessionStore.start_link(path: "/tmp/demo.db")

# Create and save a session
{:ok, session} = Session.new(%{agent_id: "assistant"})
:ok = SessionStore.save_session(store, session)

# Retrieve it
{:ok, fetched} = SessionStore.get_session(store, session.id)

# Save a run
{:ok, run} = Run.new(%{session_id: session.id})
:ok = SessionStore.save_run(store, run)

# Append events with automatic sequencing
{:ok, event} = Event.new(%{
  type: :message_sent,
  session_id: session.id,
  run_id: run.id,
  data: %{content: "Hello"}
})
{:ok, sequenced} = SessionStore.append_event_with_sequence(store, event)
sequenced.sequence_number
#=> 1

# Query events
{:ok, events} = SessionStore.get_events(store, session.id)
{:ok, run_events} = SessionStore.get_events(store, session.id, run_id: run.id)
{:ok, recent} = SessionStore.get_events(store, session.id, after: 0, limit: 10)

# List sessions with filters
{:ok, active} = SessionStore.list_sessions(store, status: :active)

# Clean up
SQLiteSessionStore.stop(store)
```

## Data Serialization

The adapter serializes data to SQLite as follows:

| Elixir type | SQLite storage | Deserialization |
|-------------|---------------|-----------------|
| Atoms (e.g. `:active`) | TEXT string (`"active"`) | `String.to_existing_atom/1` |
| Maps | TEXT JSON via `Jason.encode!/1` | `Jason.decode!/1` with keys atomized |
| Lists | TEXT JSON via `Jason.encode!/1` | `Jason.decode!/1` |
| DateTime | TEXT ISO 8601 | `DateTime.from_iso8601/1` |
| `nil` | NULL | `nil` |

Map keys are converted back to atoms on read using `String.to_atom/1`.

## Notes and Caveats

- **Atom values do not survive JSON roundtrip.** An atom value like `:foo`
  stored inside a `metadata` map will be serialized as the string `"foo"` in
  JSON. When read back, map keys are atomized but map values remain strings.
  If you rely on atom values inside maps, compare against strings after a
  roundtrip.

- **Single-writer model.** The GenServer serializes all writes through a single
  process. This is safe for concurrent reads (WAL mode) but writes are
  sequential. For high-throughput multi-writer scenarios, use `EctoSessionStore`
  with PostgreSQL.

- **Status atoms must be pre-existing.** The adapter uses
  `String.to_existing_atom/1` to convert status strings back to atoms. If you
  store a status that has never been referenced as an atom in the current VM,
  the read will raise. In practice, the `Session`, `Run`, and `Event` modules
  define all expected status atoms.

- **Database file locking.** SQLite uses file-level locking. Only one OS process
  should write to a given database file at a time.

- **No migrations needed.** The schema is bootstrapped automatically via
  `CREATE TABLE IF NOT EXISTS` on every startup. Adding columns later requires
  manual `ALTER TABLE` statements or a new adapter version.
