defmodule AgentSessionManager.Ports.SessionStore do
  @moduledoc """
  Port (interface) for session storage operations.

  This behaviour defines the contract that all session store implementations
  must fulfill. It follows the ports and adapters pattern, allowing different
  storage backends (in-memory, PostgreSQL, Redis, etc.) to be swapped without
  changing the core business logic.

  ## Design Principles

  - **Append-only event log semantics**: Events are immutable once stored
  - **Idempotent writes**: Saving the same entity multiple times is safe
  - **Read-after-write consistency**: Active run queries reflect latest writes
  - **Concurrent access safety**: All operations must be thread-safe

  ## Implementation Requirements

  Implementations must:

  1. Handle concurrent access without race conditions
  2. Provide idempotent write operations (save_session, save_run)
  3. Maintain event append order
  4. Deduplicate events by ID
  5. Return proper error tuples for not-found cases

  ## Usage

  The SessionStore is typically accessed through a store instance (e.g., a GenServer pid
  or an Agent reference):

      # Using the behaviour directly with a store instance
      {:ok, store} = InMemorySessionStore.start_link([])
      SessionStore.save_session(store, session)
      {:ok, session} = SessionStore.get_session(store, session_id)

  """

  alias AgentSessionManager.Core.{Error, Event, Run, Session}

  @type store :: GenServer.server() | pid() | atom()
  @type session_id :: String.t()
  @type run_id :: String.t()
  @type filter_opts :: keyword()

  # ============================================================================
  # Session Operations
  # ============================================================================

  @doc """
  Saves a session to the store.

  This operation is idempotent - saving the same session multiple times
  should not create duplicates. If a session with the same ID exists,
  it will be updated.

  ## Parameters

  - `store` - The store instance
  - `session` - The session struct to save

  ## Returns

  - `:ok` on success
  - `{:error, Error.t()}` on failure

  ## Examples

      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)

  """
  @callback save_session(store(), Session.t()) :: :ok | {:error, Error.t()}

  @doc """
  Retrieves a session by its ID.

  ## Parameters

  - `store` - The store instance
  - `session_id` - The session's unique identifier

  ## Returns

  - `{:ok, Session.t()}` if found
  - `{:error, %Error{code: :session_not_found}}` if not found

  ## Examples

      {:ok, session} = SessionStore.get_session(store, "ses_abc123")

  """
  @callback get_session(store(), session_id()) :: {:ok, Session.t()} | {:error, Error.t()}

  @doc """
  Lists sessions with optional filtering.

  ## Parameters

  - `store` - The store instance
  - `opts` - Optional filter options:
    - `:status` - Filter by session status (e.g., `:active`, `:pending`)
    - `:agent_id` - Filter by agent ID
    - `:limit` - Maximum number of results
    - `:offset` - Number of results to skip

  ## Returns

  - `{:ok, [Session.t()]}` - List of matching sessions

  ## Examples

      {:ok, all_sessions} = SessionStore.list_sessions(store)
      {:ok, active_sessions} = SessionStore.list_sessions(store, status: :active)

  """
  @callback list_sessions(store(), filter_opts()) :: {:ok, [Session.t()]}

  @doc """
  Deletes a session by its ID.

  This operation is idempotent - deleting a non-existent session returns `:ok`.

  ## Parameters

  - `store` - The store instance
  - `session_id` - The session's unique identifier

  ## Returns

  - `:ok` on success (including when session doesn't exist)

  ## Examples

      :ok = SessionStore.delete_session(store, "ses_abc123")

  """
  @callback delete_session(store(), session_id()) :: :ok

  # ============================================================================
  # Run Operations
  # ============================================================================

  @doc """
  Saves a run to the store.

  This operation is idempotent - saving the same run multiple times
  should not create duplicates. If a run with the same ID exists,
  it will be updated.

  ## Parameters

  - `store` - The store instance
  - `run` - The run struct to save

  ## Returns

  - `:ok` on success
  - `{:error, Error.t()}` on failure

  ## Examples

      {:ok, run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run)

  """
  @callback save_run(store(), Run.t()) :: :ok | {:error, Error.t()}

  @doc """
  Retrieves a run by its ID.

  ## Parameters

  - `store` - The store instance
  - `run_id` - The run's unique identifier

  ## Returns

  - `{:ok, Run.t()}` if found
  - `{:error, %Error{code: :run_not_found}}` if not found

  ## Examples

      {:ok, run} = SessionStore.get_run(store, "run_abc123")

  """
  @callback get_run(store(), run_id()) :: {:ok, Run.t()} | {:error, Error.t()}

  @doc """
  Lists all runs for a given session.

  ## Parameters

  - `store` - The store instance
  - `session_id` - The session's unique identifier
  - `opts` - Optional filter options:
    - `:status` - Filter by run status
    - `:limit` - Maximum number of results

  ## Returns

  - `{:ok, [Run.t()]}` - List of runs for the session

  ## Examples

      {:ok, runs} = SessionStore.list_runs(store, session.id)
      {:ok, completed_runs} = SessionStore.list_runs(store, session.id, status: :completed)

  """
  @callback list_runs(store(), session_id(), filter_opts()) :: {:ok, [Run.t()]}

  @doc """
  Gets the currently active (running) run for a session.

  A run is considered active if its status is `:running`.

  This operation must provide read-after-write consistency - if a run
  was just saved with status `:running`, this function must return it
  immediately.

  ## Parameters

  - `store` - The store instance
  - `session_id` - The session's unique identifier

  ## Returns

  - `{:ok, Run.t()}` if there's an active run
  - `{:ok, nil}` if there's no active run

  ## Examples

      {:ok, active_run} = SessionStore.get_active_run(store, session.id)

  """
  @callback get_active_run(store(), session_id()) :: {:ok, Run.t() | nil}

  # ============================================================================
  # Event Operations
  # ============================================================================

  @doc """
  Appends an event to the event log.

  Events are immutable - once appended, they cannot be modified or deleted.
  This operation is idempotent - appending an event with the same ID
  multiple times will not create duplicates.

  Events must be stored in append order and returned in that same order
  by `get_events/3`.

  ## Parameters

  - `store` - The store instance
  - `event` - The event struct to append

  ## Returns

  - `:ok` on success
  - `{:error, Error.t()}` on failure

  ## Examples

      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})
      :ok = SessionStore.append_event(store, event)

  """
  @callback append_event(store(), Event.t()) :: :ok | {:error, Error.t()}

  @doc """
  Appends an event and atomically assigns a per-session sequence number.

  The returned event must include a non-nil `sequence_number`. Duplicate event IDs
  must be handled idempotently and return the originally persisted event.

  ## Parameters

  - `store` - The store instance
  - `event` - The event struct to append

  ## Returns

  - `{:ok, Event.t()}` on success
  - `{:error, Error.t()}` on failure
  """
  @callback append_event_with_sequence(store(), Event.t()) ::
              {:ok, Event.t()} | {:error, Error.t()}

  @doc """
  Retrieves events for a session with optional filtering.

  Events are returned in append order (oldest first).

  ## Parameters

  - `store` - The store instance
  - `session_id` - The session's unique identifier
  - `opts` - Optional filter options:
    - `:run_id` - Filter by run ID
    - `:type` - Filter by event type
    - `:since` - Events after this timestamp
    - `:after` - Events with sequence number strictly greater than this value
    - `:before` - Events with sequence number strictly less than this value
    - `:limit` - Maximum number of results

  ## Returns

  - `{:ok, [Event.t()]}` - List of events in append order

  ## Examples

      {:ok, all_events} = SessionStore.get_events(store, session.id)
      {:ok, run_events} = SessionStore.get_events(store, session.id, run_id: run.id)
      {:ok, message_events} = SessionStore.get_events(store, session.id, type: :message_received)

  """
  @callback get_events(store(), session_id(), filter_opts()) :: {:ok, [Event.t()]}

  @doc """
  Gets the latest assigned event sequence number for a session.

  Returns `0` when the session has no persisted events.
  """
  @callback get_latest_sequence(store(), session_id()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  # ============================================================================
  # Default implementations via defdelegate-style functions
  # ============================================================================

  @doc """
  Saves a session to the store.
  """
  @spec save_session(store(), Session.t()) :: :ok | {:error, Error.t()}
  def save_session(store, session) do
    GenServer.call(store, {:save_session, session})
  end

  @doc """
  Retrieves a session by ID.
  """
  @spec get_session(store(), session_id()) :: {:ok, Session.t()} | {:error, Error.t()}
  def get_session(store, session_id) do
    GenServer.call(store, {:get_session, session_id})
  end

  @doc """
  Lists sessions with optional filtering.
  """
  @spec list_sessions(store(), filter_opts()) :: {:ok, [Session.t()]}
  def list_sessions(store, opts \\ []) do
    GenServer.call(store, {:list_sessions, opts})
  end

  @doc """
  Deletes a session by ID.
  """
  @spec delete_session(store(), session_id()) :: :ok
  def delete_session(store, session_id) do
    GenServer.call(store, {:delete_session, session_id})
  end

  @doc """
  Saves a run to the store.
  """
  @spec save_run(store(), Run.t()) :: :ok | {:error, Error.t()}
  def save_run(store, run) do
    GenServer.call(store, {:save_run, run})
  end

  @doc """
  Retrieves a run by ID.
  """
  @spec get_run(store(), run_id()) :: {:ok, Run.t()} | {:error, Error.t()}
  def get_run(store, run_id) do
    GenServer.call(store, {:get_run, run_id})
  end

  @doc """
  Lists runs for a session.
  """
  @spec list_runs(store(), session_id(), filter_opts()) :: {:ok, [Run.t()]}
  def list_runs(store, session_id, opts \\ []) do
    GenServer.call(store, {:list_runs, session_id, opts})
  end

  @doc """
  Gets the active run for a session.
  """
  @spec get_active_run(store(), session_id()) :: {:ok, Run.t() | nil}
  def get_active_run(store, session_id) do
    GenServer.call(store, {:get_active_run, session_id})
  end

  @doc """
  Appends an event to the store.
  """
  @spec append_event(store(), Event.t()) :: :ok | {:error, Error.t()}
  def append_event(store, event) do
    GenServer.call(store, {:append_event, event})
  end

  @doc """
  Appends an event and returns the persisted event with assigned sequence_number.
  """
  @spec append_event_with_sequence(store(), Event.t()) ::
          {:ok, Event.t()} | {:error, Error.t()}
  def append_event_with_sequence(store, event) do
    GenServer.call(store, {:append_event_with_sequence, event})
  end

  @doc """
  Gets events for a session with optional filtering.
  """
  @spec get_events(store(), session_id(), filter_opts()) :: {:ok, [Event.t()]}
  def get_events(store, session_id, opts \\ []) do
    GenServer.call(store, {:get_events, session_id, opts})
  end

  @doc """
  Gets the highest assigned sequence number for the session, or `0` when empty.
  """
  @spec get_latest_sequence(store(), session_id()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def get_latest_sequence(store, session_id) do
    GenServer.call(store, {:get_latest_sequence, session_id})
  end
end
