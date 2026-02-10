# Persistence Overview

AgentSessionManager uses a pluggable persistence architecture based on ports and
adapters.

## Ports

### SessionStore

`AgentSessionManager.Ports.SessionStore` is the canonical persistence boundary
for sessions, runs, and events.

Key callbacks:

- Sessions: `save_session/2`, `get_session/2`, `list_sessions/2`, `delete_session/2`
- Runs: `save_run/2`, `get_run/2`, `list_runs/3`, `get_active_run/2`
- Events: `append_event/2`, `append_event_with_sequence/2`, `append_events/2`,
  `get_events/3`, `get_latest_sequence/2`
- Atomic write: `flush/2`

Design guarantees:

- Append-only event semantics
- Idempotent writes for duplicate IDs
- Atomic sequence assignment for persisted events
- Store-level thread safety

### ArtifactStore

`AgentSessionManager.Ports.ArtifactStore` stores binary artifacts.

Callbacks:

- `put/4`
- `get/3`
- `delete/3`

### QueryAPI

`AgentSessionManager.Ports.QueryAPI` provides cross-session read APIs:

- `search_sessions/2`
- `get_session_stats/2`
- `search_runs/2`
- `get_usage_summary/2`
- `search_events/2`
- `count_events/2`
- `export_session/3`

Query refs are module-backed:

```elixir
query = {AgentSessionManager.Adapters.EctoQueryAPI, MyApp.Repo}
{:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "my-agent")
```

### Maintenance

`AgentSessionManager.Ports.Maintenance` provides retention and integrity
operations:

- `execute/2`
- `soft_delete_expired_sessions/2`
- `hard_delete_expired_sessions/2`
- `prune_session_events/3`
- `clean_orphaned_artifacts/2`
- `health_check/1`

Maintenance refs are also module-backed:

```elixir
maint = {AgentSessionManager.Adapters.EctoMaintenance, MyApp.Repo}
policy = RetentionPolicy.new(max_completed_session_age_days: 90)
{:ok, report} = Maintenance.execute(maint, policy)
```

## Adapters

### InMemorySessionStore

- Process-local, volatile storage
- Best for tests and local development

```elixir
{:ok, store} = InMemorySessionStore.start_link([])
```

### EctoSessionStore

- Durable SQL-backed session storage
- Works with PostgreSQL, SQLite, and other Ecto-compatible adapters
- Recommended default for production and for durable local SQLite use

```elixir
{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)
```

### S3ArtifactStore

- Durable object storage for large binary payloads

```elixir
{:ok, artifacts} = S3ArtifactStore.start_link(bucket: "my-artifacts")
```

### CompositeSessionStore

- Combines one SessionStore and one ArtifactStore under one process

```elixir
{:ok, store} = CompositeSessionStore.start_link(
  session_store: session_store,
  artifact_store: artifact_store
)
```

## Query and Maintenance with Ecto

`EctoQueryAPI` and `EctoMaintenance` operate directly against a Repo and can run
independently from the SessionStore GenServer.

```elixir
query = {EctoQueryAPI, MyApp.Repo}
maint = {EctoMaintenance, MyApp.Repo}

{:ok, summary} = QueryAPI.get_usage_summary(query)
{:ok, issues} = Maintenance.health_check(maint)
```

## Event Persistence Flow

`EventPipeline` enforces event build/validation and persistence:

1. Build normalized events through `EventBuilder`
2. Validate each event (shape warnings are attached, not rejected)
3. Persist each event with `SessionStore.append_event_with_sequence/2`
4. Emit telemetry for persisted/rejected events

`EventPipeline.process_batch/3` validates a batch first and persists it via
`SessionStore.append_events/2` when you already have a batch to commit.

For execution finalization, `SessionManager` calls `SessionStore.flush/2` to
atomically persist the final session/run state (and any buffered events in
transactional adapters).

## Choosing an Adapter

- `InMemorySessionStore`: fastest local tests, no durability
- `EctoSessionStore + SQLite`: single-node durable deployments, CLI tools
- `EctoSessionStore + PostgreSQL`: multi-node production deployments
- `S3ArtifactStore`: large artifact payloads and long-term retention
- `CompositeSessionStore`: split session/event and artifact backends

## SessionManager Integration

Pass a SessionStore reference into `SessionManager` operations:

```elixir
{:ok, result} = SessionManager.run_once(store, adapter, %{messages: messages})
```

All store adapters are GenServers and can be supervised and registered by name.
