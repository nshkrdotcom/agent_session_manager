# Custom Persistence Guide

This guide explains how to implement your own storage adapters for AgentSessionManager. The library uses a ports-and-adapters architecture with two behaviour contracts: `SessionStore` for structured session/run/event data, and `ArtifactStore` for binary blobs. You can implement either or both.

## Prerequisites

- Familiarity with GenServer and OTP behaviours
- Understanding of the core domain types: `Session`, `Run`, `Event`, and `Error`
- A running `InMemorySessionStore` to use as a reference implementation

## The SessionStore Behaviour

The `AgentSessionManager.Ports.SessionStore` behaviour defines 12 callbacks organized into three groups.

### Session Operations (4 callbacks)

| Callback | Return | Description |
|----------|--------|-------------|
| `save_session(store, session)` | `:ok \| {:error, Error.t()}` | Upsert a session by ID |
| `get_session(store, session_id)` | `{:ok, Session.t()} \| {:error, Error.t()}` | Fetch by ID, or `:session_not_found` |
| `list_sessions(store, opts)` | `{:ok, [Session.t()]}` | Filter by `:status`, `:agent_id`, `:limit`, `:offset` |
| `delete_session(store, session_id)` | `:ok` | Idempotent delete |

### Run Operations (4 callbacks)

| Callback | Return | Description |
|----------|--------|-------------|
| `save_run(store, run)` | `:ok \| {:error, Error.t()}` | Upsert a run by ID |
| `get_run(store, run_id)` | `{:ok, Run.t()} \| {:error, Error.t()}` | Fetch by ID, or `:run_not_found` |
| `list_runs(store, session_id, opts)` | `{:ok, [Run.t()]}` | List runs for a session, filter by `:status`, `:limit` |
| `get_active_run(store, session_id)` | `{:ok, Run.t() \| nil}` | Find the run with status `:running`, or `nil` |

### Event Operations (4 callbacks)

| Callback | Return | Description |
|----------|--------|-------------|
| `append_event(store, event)` | `:ok \| {:error, Error.t()}` | Append an event; idempotent by event ID |
| `append_event_with_sequence(store, event)` | `{:ok, Event.t()} \| {:error, Error.t()}` | Append and atomically assign a sequence number |
| `get_events(store, session_id, opts)` | `{:ok, [Event.t()]}` | Query events; supports `:run_id`, `:type`, `:after`, `:before`, `:limit`, `:wait_timeout_ms` |
| `get_latest_sequence(store, session_id)` | `{:ok, non_neg_integer()} \| {:error, Error.t()}` | Return highest assigned sequence number, or `0` |

## The ArtifactStore Behaviour

The `AgentSessionManager.Ports.ArtifactStore` behaviour defines 3 callbacks for binary blob storage:

| Callback | Return | Description |
|----------|--------|-------------|
| `put(store, key, data, opts)` | `:ok \| {:error, Error.t()}` | Store binary data under a string key; overwrites existing |
| `get(store, key, opts)` | `{:ok, binary()} \| {:error, Error.t()}` | Retrieve data by key; `:not_found` if missing |
| `delete(store, key, opts)` | `:ok \| {:error, Error.t()}` | Remove data by key; idempotent |

## Key Implementation Patterns

### GenServer-Based Architecture

All built-in adapters use GenServer as the process model. The port modules (`SessionStore`, `ArtifactStore`) dispatch calls via `GenServer.call/2` with specific message tuples. Your adapter must handle these messages in `handle_call/3`:

```elixir
# SessionStore dispatches:
{:save_session, session}
{:get_session, session_id}
{:list_sessions, opts}
{:delete_session, session_id}
{:save_run, run}
{:get_run, run_id}
{:list_runs, session_id, opts}
{:get_active_run, session_id}
{:append_event, event}
{:append_event_with_sequence, event}
{:get_events, session_id, opts}
{:get_latest_sequence, session_id}

# ArtifactStore dispatches:
{:put_artifact, key, data, opts}
{:get_artifact, key, opts}
{:delete_artifact, key, opts}
```

### Idempotent Writes

All write operations must be idempotent:

- `save_session/2` and `save_run/2` use upsert semantics -- if an entity with the same ID exists, update it.
- `append_event/2` and `append_event_with_sequence/2` must deduplicate by event ID. If an event with the same ID is appended again, return success (or the original event) without creating a duplicate.
- `delete_session/2` and `ArtifactStore.delete/3` return `:ok` even if the target does not exist.

### Atomic Sequence Assignment

`append_event_with_sequence/2` must atomically:

1. Read the current highest sequence number for the session
2. Increment it
3. Store the event with the new sequence number
4. Update the sequence counter

All four steps must happen within a single atomic unit (transaction, lock, or serialized GenServer call) to prevent gaps or duplicates in the sequence.

### Error Handling with Core.Error

All errors must be returned as `AgentSessionManager.Core.Error` structs. Use the appropriate error codes:

```elixir
alias AgentSessionManager.Core.Error

# Resource not found
{:error, Error.new(:session_not_found, "Session not found: #{session_id}")}
{:error, Error.new(:run_not_found, "Run not found: #{run_id}")}

# Storage failures
{:error, Error.new(:storage_error, "Connection lost")}
{:error, Error.new(:storage_write_failed, "Write rejected: #{reason}")}
{:error, Error.new(:storage_read_failed, "Read failed: #{reason}")}
{:error, Error.new(:storage_connection_failed, "Cannot connect")}
```

The storage error codes (`:storage_error`, `:storage_write_failed`, `:storage_read_failed`, `:storage_connection_failed`) are the standard codes for persistence failures. `:storage_connection_failed` and `:timeout` are marked as retryable by `Error.retryable?/1`.

## Skeleton Adapter: RedisSessionStore

Below is a minimal skeleton showing the structure of a custom `SessionStore` adapter. Replace the Redis-specific logic with your actual storage calls.

```elixir
defmodule MyApp.RedisSessionStore do
  @moduledoc """
  Redis-backed session store.
  """

  use GenServer

  @behaviour AgentSessionManager.Ports.SessionStore

  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # -------------------------------------------------------------------
  # SessionStore Behaviour
  # -------------------------------------------------------------------

  @impl SessionStore
  def save_session(store, %Session{} = session),
    do: GenServer.call(store, {:save_session, session})

  @impl SessionStore
  def get_session(store, session_id),
    do: GenServer.call(store, {:get_session, session_id})

  @impl SessionStore
  def list_sessions(store, opts \\ []),
    do: GenServer.call(store, {:list_sessions, opts})

  @impl SessionStore
  def delete_session(store, session_id),
    do: GenServer.call(store, {:delete_session, session_id})

  @impl SessionStore
  def save_run(store, %Run{} = run),
    do: GenServer.call(store, {:save_run, run})

  @impl SessionStore
  def get_run(store, run_id),
    do: GenServer.call(store, {:get_run, run_id})

  @impl SessionStore
  def list_runs(store, session_id, opts \\ []),
    do: GenServer.call(store, {:list_runs, session_id, opts})

  @impl SessionStore
  def get_active_run(store, session_id),
    do: GenServer.call(store, {:get_active_run, session_id})

  @impl SessionStore
  def append_event(store, %Event{} = event),
    do: GenServer.call(store, {:append_event, event})

  @impl SessionStore
  def append_event_with_sequence(store, %Event{} = event),
    do: GenServer.call(store, {:append_event_with_sequence, event})

  @impl SessionStore
  def get_events(store, session_id, opts \\ []),
    do: GenServer.call(store, {:get_events, session_id, opts})

  @impl SessionStore
  def get_latest_sequence(store, session_id),
    do: GenServer.call(store, {:get_latest_sequence, session_id})

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    redis_url = Keyword.fetch!(opts, :url)

    case connect_to_redis(redis_url) do
      {:ok, conn} ->
        {:ok, %{conn: conn}}

      {:error, reason} ->
        {:stop, Error.new(:storage_connection_failed, "Redis: #{inspect(reason)}")}
    end
  end

  @impl GenServer
  def handle_call({:save_session, session}, _from, state) do
    key = "asm:session:#{session.id}"
    data = session |> Session.to_map() |> Jason.encode!()

    case redis_set(state.conn, key, data) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, storage_error(reason)}, state}
    end
  end

  def handle_call({:get_session, session_id}, _from, state) do
    key = "asm:session:#{session_id}"

    case redis_get(state.conn, key) do
      {:ok, nil} ->
        {:reply, {:error, Error.new(:session_not_found, "Session not found: #{session_id}")}, state}

      {:ok, data} ->
        {:ok, session} = data |> Jason.decode!() |> Session.from_map()
        {:reply, {:ok, session}, state}

      {:error, reason} ->
        {:reply, {:error, storage_error(reason)}, state}
    end
  end

  # ... implement remaining handle_call clauses for all 12 operations ...

  def handle_call({:append_event_with_sequence, event}, _from, state) do
    # Atomic sequence assignment example using Redis MULTI/EXEC:
    #
    # 1. Check for duplicate event ID (idempotent)
    # 2. INCR the session sequence counter
    # 3. Store the event with the assigned sequence number
    # 4. Return the sequenced event

    case redis_get(state.conn, "asm:event:#{event.id}") do
      {:ok, existing} when not is_nil(existing) ->
        {:ok, stored} = existing |> Jason.decode!() |> Event.from_map()
        {:reply, {:ok, stored}, state}

      _ ->
        {:ok, next_seq} = redis_incr(state.conn, "asm:seq:#{event.session_id}")
        sequenced = %{event | sequence_number: next_seq}
        data = sequenced |> Event.to_map() |> Jason.encode!()

        :ok = redis_set(state.conn, "asm:event:#{event.id}", data)
        :ok = redis_rpush(state.conn, "asm:events:#{event.session_id}", data)

        {:reply, {:ok, sequenced}, state}
    end
  end

  # -------------------------------------------------------------------
  # Private Helpers (replace with actual Redis client calls)
  # -------------------------------------------------------------------

  defp connect_to_redis(_url), do: {:ok, :fake_conn}
  defp redis_set(_conn, _key, _value), do: :ok
  defp redis_get(_conn, _key), do: {:ok, nil}
  defp redis_incr(_conn, _key), do: {:ok, 1}
  defp redis_rpush(_conn, _key, _value), do: :ok

  defp storage_error(reason) do
    Error.new(:storage_error, "Redis error: #{inspect(reason)}")
  end
end
```

## Testing Against the Reference

The `InMemorySessionStore` is the canonical reference implementation. Use it to validate your adapter's behavior by running the same test scenarios against both:

```elixir
defmodule MyApp.RedisSessionStoreTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Core.{Session, Run, Event}
  alias AgentSessionManager.Ports.SessionStore

  setup do
    {:ok, store} = MyApp.RedisSessionStore.start_link(url: "redis://localhost:6379/15")
    # Flush test database between runs
    %{store: store}
  end

  test "save and retrieve session", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    assert :ok = SessionStore.save_session(store, session)
    assert {:ok, ^session} = SessionStore.get_session(store, session.id)
  end

  test "get_session returns error for missing ID", %{store: store} do
    assert {:error, %{code: :session_not_found}} =
             SessionStore.get_session(store, "nonexistent")
  end

  test "save_session is idempotent", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    assert :ok = SessionStore.save_session(store, session)
    assert :ok = SessionStore.save_session(store, session)
    {:ok, sessions} = SessionStore.list_sessions(store)
    assert length(sessions) == 1
  end

  test "append_event_with_sequence assigns monotonic numbers", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    :ok = SessionStore.save_session(store, session)

    {:ok, e1} = Event.new(%{type: :session_created, session_id: session.id})
    {:ok, e2} = Event.new(%{type: :session_started, session_id: session.id})

    {:ok, stored1} = SessionStore.append_event_with_sequence(store, e1)
    {:ok, stored2} = SessionStore.append_event_with_sequence(store, e2)

    assert stored1.sequence_number == 1
    assert stored2.sequence_number == 2
  end

  test "duplicate event append is idempotent", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    :ok = SessionStore.save_session(store, session)

    {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})
    {:ok, first} = SessionStore.append_event_with_sequence(store, event)
    {:ok, second} = SessionStore.append_event_with_sequence(store, event)

    assert first.sequence_number == second.sequence_number
  end

  test "get_active_run returns nil when no running run", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    :ok = SessionStore.save_session(store, session)
    assert {:ok, nil} = SessionStore.get_active_run(store, session.id)
  end

  test "delete_session is idempotent", %{store: store} do
    assert :ok = SessionStore.delete_session(store, "nonexistent-id")
  end
end
```

Key properties to verify:

- **Idempotent writes**: saving the same session/run/event twice produces no duplicates
- **Not-found errors**: `get_session` returns `{:error, %Error{code: :session_not_found}}`; `get_run` returns `{:error, %Error{code: :run_not_found}}`
- **Monotonic sequences**: `append_event_with_sequence` returns strictly increasing sequence numbers per session
- **Event ordering**: `get_events` returns events in append order (oldest first)
- **Filter correctness**: `:status`, `:run_id`, `:type`, `:after`, `:before`, and `:limit` filters work as expected
- **Active run semantics**: `get_active_run` returns the run with `status: :running`, or `nil`

## Notes and Caveats

- **The port module handles GenServer dispatch.** When callers use `SessionStore.save_session(store, session)`, the port module sends `GenServer.call(store, {:save_session, session})`. Your adapter must handle these exact message tuples. The simplest approach is to define both the `@impl SessionStore` callback functions (which call `GenServer.call`) and the `handle_call` clauses (which do the actual work), mirroring the pattern in `InMemorySessionStore`.

- **wait_timeout_ms is optional.** The `get_events` callback accepts a `:wait_timeout_ms` option for long-polling. If your backend does not support blocking queries, you can safely ignore this option and return an empty list immediately.

- **Serialization round-trips.** Use `Session.to_map/1` / `Session.from_map/1`, `Run.to_map/1` / `Run.from_map/1`, and `Event.to_map/1` / `Event.from_map/1` for serialization. These handle atom/string key conversion and DateTime formatting.

- **Do not lose schema_version.** When persisting events, always store and restore the `schema_version` field. See the [Event Schema Versioning](event_schema_versioning.md) guide for details.

- **Connection lifecycle.** Open connections in `init/1` and close them in `terminate/2`. If your backend library uses a pool (e.g., Ecto, Redix), start the pool as a separate supervised process and pass its reference to the adapter.
