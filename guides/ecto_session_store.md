# EctoSessionStore

`AgentSessionManager.Adapters.EctoSessionStore` is a database-backed session
store that works with any Ecto-compatible database. It delegates all SQL through
your application's Ecto Repo, making it the right choice for production
deployments that already use Ecto and need multi-node support.

## Prerequisites

Add `ecto_sql` and a database adapter to your `mix.exs`:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"},
    {:ecto_sql, "~> 3.12"},
    {:postgrex, "~> 0.19"}       # for PostgreSQL
    # or {:ecto_sqlite3, "~> 0.17"} for SQLite
    # or {:myxql, "~> 0.7"}       for MySQL
  ]
end
```

You must have an Ecto Repo configured in your application. If you do not have
one yet, follow the [Ecto getting started guide](https://hexdocs.pm/ecto/getting-started.html).

## Running the Migration

The adapter includes a migration module that creates the required tables. Generate
a migration in your project and delegate to it:

```bash
mix ecto.gen.migration add_agent_session_manager
```

Then edit the generated file:

```elixir
defmodule MyApp.Repo.Migrations.AddAgentSessionManager do
  use Ecto.Migration

  def up do
    AgentSessionManager.Adapters.EctoSessionStore.Migration.up()
  end

  def down do
    AgentSessionManager.Adapters.EctoSessionStore.Migration.down()
  end
end
```

Run the migration:

```bash
mix ecto.migrate
```

### Tables Created

The migration creates four tables:

| Table | Purpose |
|-------|---------|
| `asm_sessions` | Session records with status, metadata, context, and tags |
| `asm_runs` | Run records linked to sessions |
| `asm_events` | Append-only event log with per-session sequence numbers |
| `asm_session_sequences` | Atomic sequence counters for event ordering |

Indexes are added for status, agent_id, session_id, type, and a unique index on
`(session_id, sequence_number)` for event ordering.

## Configuration

Start the adapter with a reference to your Ecto Repo:

```elixir
alias AgentSessionManager.Adapters.EctoSessionStore

# Basic usage
{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)

# With a registered name
{:ok, store} = EctoSessionStore.start_link(
  repo: MyApp.Repo,
  name: :session_store
)
```

### Options

| Option  | Required | Description |
|---------|----------|-------------|
| `:repo` | Yes | An Ecto Repo module (e.g. `MyApp.Repo`) |
| `:name` | No  | GenServer name for registration |

### Supervision Tree

```elixir
children = [
  MyApp.Repo,
  {EctoSessionStore, repo: MyApp.Repo, name: :session_store}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Make sure the Repo is started before the EctoSessionStore.

## Ecto Schemas

The adapter includes Ecto schemas in
`AgentSessionManager.Adapters.EctoSessionStore.Schemas` for reference and
potential use in custom queries:

| Schema | Table | Primary Key |
|--------|-------|-------------|
| `SessionSchema` | `asm_sessions` | `:id` (string, no autogenerate) |
| `RunSchema` | `asm_runs` | `:id` (string, no autogenerate) |
| `EventSchema` | `asm_events` | `:id` (string, no autogenerate) |
| `SessionSequenceSchema` | `asm_session_sequences` | `:session_id` (string) |

Each schema defines a `changeset/2` function with appropriate validations.

## How Queries Work

The adapter uses `Ecto.Query` and the schemas defined in
`EctoSessionStore.Schemas` for all database operations. The implementation is
tested against PostgreSQL and SQLite. Most SQL differences are handled by Ecto,
but the sequence allocator relies on `insert_all(..., returning: ...)`, which
is not supported by every Ecto adapter (for example, MySQL). If you target a
different database, you may need to replace the sequence allocation strategy.

Upserts use `Repo.insert/2` with `on_conflict: {:replace_all_except, [:id]}`
and `conflict_target: :id`, which Ecto translates to the correct syntax for
each database backend.

Sequence assignment for events is wrapped in a `Repo.transaction/1` call:

1. Check for duplicate event ID (idempotent handling).
2. Read or create the sequence counter in `asm_session_sequences`.
3. Insert the event with the next sequence number.
4. Update the counter.

The transaction isolates the read-increment-write cycle and prevents duplicate
sequence numbers under concurrent access.

## Usage Examples

```elixir
alias AgentSessionManager.Adapters.EctoSessionStore
alias AgentSessionManager.Ports.SessionStore
alias AgentSessionManager.Core.{Session, Run, Event}

# Start the store
{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)

# Create and persist a session
{:ok, session} = Session.new(%{agent_id: "assistant"})
:ok = SessionStore.save_session(store, session)

# Retrieve it
{:ok, fetched} = SessionStore.get_session(store, session.id)

# Save a run
{:ok, run} = Run.new(%{session_id: session.id})
:ok = SessionStore.save_run(store, run)

# Append an event with sequence assignment
{:ok, event} = Event.new(%{
  type: :message_sent,
  session_id: session.id,
  run_id: run.id,
  data: %{content: "Hello"}
})
{:ok, sequenced} = SessionStore.append_event_with_sequence(store, event)
sequenced.sequence_number
#=> 1

# Query events with filters
{:ok, all_events} = SessionStore.get_events(store, session.id)
{:ok, run_events} = SessionStore.get_events(store, session.id, run_id: run.id)
{:ok, page} = SessionStore.get_events(store, session.id, after: 0, limit: 50)

# List sessions
{:ok, sessions} = SessionStore.list_sessions(store, status: :active, limit: 20)

# Get the active run for a session
{:ok, active_run} = SessionStore.get_active_run(store, session.id)

# Delete a session
:ok = SessionStore.delete_session(store, session.id)
```

## Using with SessionManager

```elixir
alias AgentSessionManager.SessionManager

{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)
{:ok, adapter} = ClaudeAdapter.start_link(api_key: api_key)

{:ok, result} = SessionManager.run_once(store, adapter, %{
  messages: [%{role: "user", content: "Summarize this document."}]
})
```

## Schema V2 Migration

Version 0.8.0 introduces a V2 migration that adds persistence redesign columns.
Generate a second migration and delegate to `MigrationV2`:

```bash
mix ecto.gen.migration add_agent_session_manager_v2
```

```elixir
defmodule MyApp.Repo.Migrations.AddAgentSessionManagerV2 do
  use Ecto.Migration

  def up do
    AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.up()
  end

  def down do
    AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.down()
  end
end
```

### V2 Schema Changes

| Table | New Columns |
|-------|-------------|
| `asm_sessions` | `deleted_at` (soft-delete timestamp) |
| `asm_runs` | `provider` (string), `provider_metadata` (JSON map) |
| `asm_events` | `provider` (string), `correlation_id` (string) |
| `asm_artifacts` | New table for artifact metadata tracking |

The `asm_artifacts` table schema:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | string | Primary key |
| `session_id` | string | Associated session (optional) |
| `run_id` | string | Associated run (optional) |
| `key` | string | Unique artifact key |
| `content_type` | string | MIME type |
| `byte_size` | bigint | Artifact size |
| `checksum_sha256` | string | Content checksum |
| `storage_backend` | string | Backend name (e.g., "s3", "file") |
| `storage_ref` | string | Backend-specific reference |
| `metadata` | JSON | Additional metadata |
| `created_at` | datetime | Creation timestamp |
| `deleted_at` | datetime | Soft-delete timestamp |

## QueryAPI and Maintenance

With V2 migrations applied, you can use the QueryAPI and Maintenance adapters
for cross-session queries and lifecycle management:

```elixir
alias AgentSessionManager.Adapters.{EctoQueryAPI, EctoMaintenance}
alias AgentSessionManager.Persistence.RetentionPolicy

# Plain module-backed refs (no dedicated GenServer required)
query = {EctoQueryAPI, MyApp.Repo}
maint = {EctoMaintenance, MyApp.Repo}

# Search and aggregate
{:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "my-agent")
{:ok, summary} = QueryAPI.get_usage_summary(query)

# Run maintenance
policy = RetentionPolicy.new(max_completed_session_age_days: 90)
{:ok, report} = Maintenance.execute(maint, policy)
```

## Notes and Caveats

- **Cross-database portability via Ecto.Query.** Most queries are portable, but
  sequence allocation relies on `insert_all(..., returning: ...)` and is only
  implemented for SQLite and PostgreSQL. Other adapters (e.g., MySQL) need a
  different sequence allocation strategy or a custom store.

- **Token usage filters are adapter-limited.** `search_runs/2` options like
  `:min_tokens` and `:token_usage_desc` rely on JSON extraction and are only
  supported on SQLite and PostgreSQL adapters. Other adapters return a
  `:query_error`.

- **Atom values do not survive JSON roundtrip.** Maps stored in `metadata`,
  `context`, `data`, and similar fields are JSON-encoded. Atom values inside
  those maps become strings. Known keys may be read as atoms; unknown keys are
  preserved as strings.

- **Status atoms must be pre-existing.** The adapter uses
  `String.to_existing_atom/1` for status fields. All status atoms are defined
  by the `Session`, `Run`, and `Event` modules and are safe to convert.

- **Transaction isolation.** Event sequence assignment relies on database
  transactions. PostgreSQL provides the strongest guarantees here. If you use
  SQLite through Ecto, be aware of its single-writer limitation.

- **Migration versioning.** The included migration creates the initial schema.
  Future versions of the library may ship additional migration modules for
  schema changes. Always wrap the call in your own migration file so Ecto can
  track the version.
