# CompositeSessionStore

The `CompositeSessionStore` combines a `SessionStore` backend and an `ArtifactStore` backend behind a single process. It implements both the `SessionStore` and `ArtifactStore` behaviours, delegating each call to the appropriate underlying store. This lets you use one pid (or registered name) for all persistence operations.

## Purpose

Most applications need two kinds of storage:

- **Session storage** -- sessions, runs, and events (structured, queryable data)
- **Artifact storage** -- large binary blobs like workspace patches and snapshot manifests

These are defined by separate behaviour contracts (`SessionStore` and `ArtifactStore`). The `CompositeSessionStore` wraps one of each, presenting a unified handle to the rest of your system. You can combine any session backend (InMemory, Ecto) with any artifact backend (File, S3) without changing calling code.

## Configuration

The composite store requires two already-started backend processes:

| Option | Required | Description |
|--------|----------|-------------|
| `:session_store` | Yes | A pid or registered name of a running `SessionStore` implementation |
| `:artifact_store` | Yes | A pid or registered name of a running `ArtifactStore` implementation |
| `:name` | No | Optional registered name for the composite GenServer |

## Starting the Store

Start your backend stores first, then pass them to the composite:

```elixir
alias AgentSessionManager.Adapters.{
  CompositeSessionStore,
  EctoSessionStore,
  S3ArtifactStore
}

# Start the session backend
{:ok, session_store} = EctoSessionStore.start_link(repo: MyApp.Repo)

# Start the artifact backend
{:ok, s3} = S3ArtifactStore.start_link(
  bucket: "my-app-artifacts",
  prefix: "asm/artifacts/"
)

# Combine them
{:ok, store} = CompositeSessionStore.start_link(
  session_store: session_store,
  artifact_store: s3
)
```

With a registered name for supervision trees:

```elixir
{:ok, store} = CompositeSessionStore.start_link(
  session_store: session_store,
  artifact_store: s3,
  name: MyApp.Store
)
```

## Usage

Once started, use the composite store handle with the standard port modules. Session operations are routed to the session backend; artifact operations are routed to the artifact backend.

### Session Operations

```elixir
alias AgentSessionManager.Ports.SessionStore
alias AgentSessionManager.Core.{Session, Run, Event}

# Save and retrieve a session
{:ok, session} = Session.new(%{agent_id: "my-agent"})
:ok = SessionStore.save_session(store, session)
{:ok, fetched} = SessionStore.get_session(store, session.id)

# List sessions with filters
{:ok, sessions} = SessionStore.list_sessions(store, status: :active, limit: 10)

# Run operations
{:ok, run} = Run.new(%{session_id: session.id})
:ok = SessionStore.save_run(store, run)
{:ok, active} = SessionStore.get_active_run(store, session.id)

# Event operations
{:ok, event} = Event.new(%{
  type: :message_received,
  session_id: session.id,
  run_id: run.id,
  data: %{content: "Hello!"}
})

{:ok, sequenced} = SessionStore.append_event_with_sequence(store, event)
{:ok, events} = SessionStore.get_events(store, session.id, after: 0, limit: 50)
```

### Artifact Operations

```elixir
alias AgentSessionManager.Ports.ArtifactStore

# Store a workspace patch
:ok = ArtifactStore.put(store, "patch-#{run.id}", patch_binary)

# Retrieve it later
{:ok, data} = ArtifactStore.get(store, "patch-#{run.id}")

# Clean up
:ok = ArtifactStore.delete(store, "patch-#{run.id}")
```

## How Delegation Works

The `CompositeSessionStore` is a GenServer that holds references to both backends in its state:

```
%{session_store: #PID<0.250.0>, artifact_store: #PID<0.251.0>}
```

When a `GenServer.call` arrives, the `handle_call/3` clauses inspect the message tag and forward to the correct backend using the corresponding port module:

- Session/run/event messages (e.g., `{:save_session, session}`) are forwarded via `SessionStore.save_session(state.session_store, session)`
- Artifact messages (e.g., `{:put_artifact, key, data, opts}`) are forwarded via `ArtifactStore.put(state.artifact_store, key, data, opts)`

This means calls go through two GenServer hops: caller -> composite -> backend. For most workloads this overhead is negligible. If you need to bypass it for high-throughput artifact writes, you can call the artifact backend directly while still using the composite for session operations.

## Example: Ecto(SQLite) + File (Development)

A lighter-weight setup for local development:

```elixir
alias AgentSessionManager.Adapters.{
  CompositeSessionStore,
  EctoSessionStore,
  FileArtifactStore
}

{:ok, session_store} = EctoSessionStore.start_link(repo: MyApp.Repo)
{:ok, files} = FileArtifactStore.start_link(root: "priv/dev_artifacts")

{:ok, store} = CompositeSessionStore.start_link(
  session_store: session_store,
  artifact_store: files
)
```

## Example: InMemory + File (Testing)

For tests that need artifact persistence but throwaway session state:

```elixir
alias AgentSessionManager.Adapters.{
  CompositeSessionStore,
  InMemorySessionStore,
  FileArtifactStore
}

{:ok, mem} = InMemorySessionStore.start_link()
{:ok, files} = FileArtifactStore.start_link(root: System.tmp_dir!())

{:ok, store} = CompositeSessionStore.start_link(
  session_store: mem,
  artifact_store: files
)
```

## Notes and Caveats

- **Start order matters.** Both backend processes must be running before you call `CompositeSessionStore.start_link/1`. If either pid is dead, calls through the composite will fail with a GenServer exit.

- **No cross-store transactions.** The composite delegates independently to each backend. There is no atomicity guarantee across a session write and an artifact write. If you need both to succeed or fail together, handle that in your application layer.

- **Error passthrough.** Errors from the underlying backends are returned as-is. A `:storage_error` from the SessionStore or S3 propagates directly through the composite without wrapping.

- **Supervision.** In a supervision tree, start the backends as children before the composite, or use a dedicated supervisor that guarantees start order.

- **Single caller bottleneck.** The composite is a single GenServer, so all calls are serialized through it before fanning out. For very high concurrency, consider calling the backends directly using separate references.
