# Persistence Overview

AgentSessionManager ships with a pluggable persistence layer built on the
**Ports and Adapters** pattern. Two port behaviours define the storage contract;
four concrete adapters implement them for different deployment scenarios.

## Ports

### SessionStore (12 callbacks)

`AgentSessionManager.Ports.SessionStore` defines all operations for sessions,
runs, and events:

| Group    | Callbacks |
|----------|-----------|
| Sessions | `save_session/2`, `get_session/2`, `list_sessions/2`, `delete_session/2` |
| Runs     | `save_run/2`, `get_run/2`, `list_runs/3`, `get_active_run/2` |
| Events   | `append_event/2`, `append_event_with_sequence/2`, `get_events/3`, `get_latest_sequence/2` |

All implementations must guarantee:

- Append-only event log semantics (events are immutable once stored)
- Idempotent writes (saving the same entity twice is safe)
- Read-after-write consistency for active run queries
- Concurrent access safety

### ArtifactStore (3 callbacks)

`AgentSessionManager.Ports.ArtifactStore` handles large binary blobs
(workspace patches, snapshot manifests, etc.):

| Callback | Purpose |
|----------|---------|
| `put/4`  | Store binary data under a string key |
| `get/3`  | Retrieve binary data by key |
| `delete/3` | Remove an artifact by key |

## Adapters

### Adapter Comparison

| Feature | InMemory | SQLite | Ecto | S3 | Composite |
|---------|----------|--------|------|----|-----------|
| Port | SessionStore | SessionStore | SessionStore | ArtifactStore | Both |
| Persistence | No (process lifetime) | Yes (file) | Yes (database) | Yes (object storage) | Delegates |
| Multi-node | No | No | Yes | Yes | Depends on backends |
| Dependencies | None | `exqlite` | `ecto_sql` + DB adapter | `ex_aws`, `ex_aws_s3` | None (wraps others) |
| Best for | Tests, dev | CLI tools, single-node | Production, multi-node | Large blobs, backups | Combining session + artifact stores |

### InMemorySessionStore

The default adapter. Stores everything in ETS tables backed by a GenServer.
Data is lost when the process stops. Use it for tests and rapid prototyping.

```elixir
{:ok, store} = InMemorySessionStore.start_link([])
```

### SQLiteSessionStore

A file-backed session store using raw `exqlite` calls. Runs in WAL mode for
concurrent reads during writes. Ideal for CLI tools and single-node deployments.
See the [SQLiteSessionStore guide](sqlite_session_store.md) for details.

```elixir
{:ok, store} = SQLiteSessionStore.start_link(path: "/tmp/sessions.db")
```

### EctoSessionStore

Uses an Ecto Repo for persistence, supporting PostgreSQL, MySQL, SQLite, and any
other Ecto-compatible database. Best for production multi-node deployments that
already use Ecto. See the [EctoSessionStore guide](ecto_session_store.md) for
details.

```elixir
{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)
```

### S3ArtifactStore

Stores binary artifacts in S3-compatible object storage. Works with AWS S3,
MinIO, DigitalOcean Spaces, and similar services. See the
[S3ArtifactStore guide](s3_artifact_store.md) for details.

```elixir
{:ok, store} = S3ArtifactStore.start_link(bucket: "my-artifacts")
```

### CompositeSessionStore

Combines a SessionStore backend with an ArtifactStore backend behind a single
GenServer, implementing both behaviours. Session, run, and event calls are
delegated to the configured SessionStore; artifact calls go to the ArtifactStore.

```elixir
{:ok, sqlite} = SQLiteSessionStore.start_link(path: "sessions.db")
{:ok, s3} = S3ArtifactStore.start_link(bucket: "artifacts")

{:ok, store} = CompositeSessionStore.start_link(
  session_store: sqlite,
  artifact_store: s3
)

# Session operations go to SQLite
SessionStore.save_session(store, session)

# Artifact operations go to S3
ArtifactStore.put(store, "patch-123", data)
```

## QueryAPI and Maintenance Ports

In addition to the storage ports, the persistence layer includes two operational
ports for querying and lifecycle management.

### QueryAPI (7 callbacks)

`AgentSessionManager.Ports.QueryAPI` provides cross-session search, aggregation,
and export capabilities:

| Callback | Purpose |
|----------|---------|
| `search_sessions/2` | Search sessions by agent_id, status, tags |
| `get_session_stats/2` | Aggregated stats for a session (event count, providers, tokens) |
| `search_runs/2` | Search runs by provider, status, session |
| `get_usage_summary/2` | Token usage aggregation across all runs, broken down by provider |
| `search_events/2` | Search events by session, type, with cursor-based pagination |
| `count_events/2` | Count events without loading them |
| `export_session/3` | Export a session with all its runs and events |

The Ecto implementation is `AgentSessionManager.Adapters.EctoQueryAPI`.

```elixir
{:ok, query} = EctoQueryAPI.start_link(repo: MyApp.Repo)
{:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "my-agent")
{:ok, summary} = QueryAPI.get_usage_summary(query)
```

### Maintenance (6 callbacks)

`AgentSessionManager.Ports.Maintenance` handles session lifecycle and data
integrity operations:

| Callback | Purpose |
|----------|---------|
| `execute/2` | Run a full maintenance cycle (soft-delete, hard-delete, prune, clean) |
| `soft_delete_expired_sessions/2` | Soft-delete sessions past retention age |
| `hard_delete_expired_sessions/2` | Permanently delete soft-deleted sessions past hard-delete age |
| `prune_session_events/3` | Prune events in a session down to a max count |
| `clean_orphaned_artifacts/2` | Remove artifacts referencing deleted sessions |
| `health_check/1` | Check data integrity (orphaned events/runs, sequence mismatches) |

The Ecto implementation is `AgentSessionManager.Adapters.EctoMaintenance`.

```elixir
{:ok, maint} = EctoMaintenance.start_link(repo: MyApp.Repo)
policy = RetentionPolicy.new(max_completed_session_age_days: 90)
{:ok, report} = Maintenance.execute(maint, policy)
```

### RetentionPolicy

`AgentSessionManager.Persistence.RetentionPolicy` is a configurable struct that
defines retention rules for the Maintenance port:

```elixir
policy = RetentionPolicy.new(
  max_completed_session_age_days: 90,   # Soft-delete completed sessions older than 90 days
  hard_delete_after_days: 30,           # Permanently delete soft-deleted sessions after 30 days
  max_events_per_session: 10_000,       # Prune events beyond this limit
  exempt_tags: ["pinned"],              # Never soft-delete sessions with these tags
  exempt_statuses: [:active, :paused],  # Never soft-delete sessions in these statuses
  prune_event_types_first: [:message_streamed, :token_usage_updated]  # Prune low-value events first
)
```

### EventPipeline

`AgentSessionManager.Persistence.EventPipeline` sits between provider adapters
and storage, processing each event through four stages:

1. **Build** -- Normalizes the event type and constructs an `Event` struct
2. **Enrich** -- Adds provider name and correlation_id
3. **Validate** -- Structural validation (strict) and shape validation (advisory)
4. **Persist** -- Atomically appends the event with sequence assignment

The pipeline is automatically wired into `SessionManager` and does not need
manual invocation.

### ArtifactRegistry

`AgentSessionManager.Persistence.ArtifactRegistry` provides metadata tracking
for artifacts stored in the `asm_artifacts` table:

```elixir
{:ok, registry} = ArtifactRegistry.start_link(repo: MyApp.Repo)
:ok = ArtifactRegistry.register(registry, %{key: "patch-001", session_id: "ses_001", type: "diff"})
{:ok, artifact} = ArtifactRegistry.get_by_key(registry, "patch-001")
```

## Architecture Diagram

```
                  +-----------------------+
                  |   SessionManager /    |
                  |   SessionServer       |
                  +----------+------------+
                             |
              +--------------+--------------+
              |                             |
     +--------v--------+          +--------v--------+
     | SessionStore     |          | ArtifactStore   |
     | (port/behaviour) |          | (port/behaviour)|
     +--------+---------+          +--------+--------+
              |                             |
     +--------+--------+           +-------+--------+
     |        |        |           |                |
  InMemory  SQLite   Ecto    FileArtifact     S3Artifact
                                   |
                        +----------+-----------+
                        |  CompositeSessionStore |
                        | (combines both ports) |
                        +-----------------------+
```

## Choosing an Adapter

- **Development and tests** -- `InMemorySessionStore` (zero config, fast)
- **CLI tools and single-node apps** -- `SQLiteSessionStore` (durable, no server)
- **Production with an existing database** -- `EctoSessionStore` (PostgreSQL, etc.)
- **Large binary artifacts** -- `S3ArtifactStore` (offload blobs to object storage)
- **Session data in a DB, blobs in S3** -- `CompositeSessionStore` wrapping both

## Configuration with SessionManager

Pass the store as the first argument to `SessionManager` functions:

```elixir
alias AgentSessionManager.SessionManager
alias AgentSessionManager.Adapters.SQLiteSessionStore

{:ok, store} = SQLiteSessionStore.start_link(path: "sessions.db")

{:ok, result} = SessionManager.run_once(store, adapter, %{
  messages: [%{role: "user", content: "Hello"}]
})
```

All adapters are GenServers, so they can be started under a supervision tree
and referenced by name:

```elixir
children = [
  {SQLiteSessionStore, path: "sessions.db", name: :session_store}
]

Supervisor.start_link(children, strategy: :one_for_one)

# Later...
SessionStore.get_session(:session_store, session_id)
```
