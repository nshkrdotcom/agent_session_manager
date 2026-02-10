defmodule AgentSessionManager.Adapters.EctoSessionStore do
  @moduledoc """
  An Ecto-based implementation of the `SessionStore` port.

  Uses an Ecto Repo for persistence, supporting PostgreSQL, SQLite,
  MySQL, and any other Ecto-compatible database. All queries use
  `Ecto.Query` and the schemas in `EctoSessionStore.Schemas`, so
  database-specific SQL dialect differences are handled by Ecto.

  ## Configuration

      {:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)

  ## Prerequisites

  Run the migration to create required tables:

      AgentSessionManager.Adapters.EctoSessionStore.Migration.up()

  See `AgentSessionManager.Adapters.EctoSessionStore.Migration` for details.
  """

  use GenServer

  import Ecto.Query

  @behaviour AgentSessionManager.Ports.SessionStore

  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    EventSchema,
    RunSchema,
    SessionSchema,
    SessionSequenceSchema
  }

  # ============================================================================
  # Client API (SessionStore behaviour)
  # ============================================================================

  @impl SessionStore
  def save_session(store, session), do: GenServer.call(store, {:save_session, session})

  @impl SessionStore
  def get_session(store, session_id), do: GenServer.call(store, {:get_session, session_id})

  @impl SessionStore
  def list_sessions(store, opts \\ []), do: GenServer.call(store, {:list_sessions, opts})

  @impl SessionStore
  def delete_session(store, session_id),
    do: GenServer.call(store, {:delete_session, session_id})

  @impl SessionStore
  def save_run(store, run), do: GenServer.call(store, {:save_run, run})

  @impl SessionStore
  def get_run(store, run_id), do: GenServer.call(store, {:get_run, run_id})

  @impl SessionStore
  def list_runs(store, session_id, opts \\ []),
    do: GenServer.call(store, {:list_runs, session_id, opts})

  @impl SessionStore
  def get_active_run(store, session_id),
    do: GenServer.call(store, {:get_active_run, session_id})

  @impl SessionStore
  def append_event(store, event), do: GenServer.call(store, {:append_event, event})

  @impl SessionStore
  def append_event_with_sequence(store, event),
    do: GenServer.call(store, {:append_event_with_sequence, event})

  @impl SessionStore
  def get_events(store, session_id, opts \\ []),
    do: GenServer.call(store, {:get_events, session_id, opts})

  @impl SessionStore
  def get_latest_sequence(store, session_id),
    do: GenServer.call(store, {:get_latest_sequence, session_id})

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    repo = Keyword.fetch!(opts, :repo)
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, %{repo: repo}, gen_opts)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  # -- Session Operations --

  @impl GenServer
  def handle_call({:save_session, session}, _from, %{repo: repo} = state) do
    attrs = session_to_attrs(session)
    changeset = SessionSchema.changeset(%SessionSchema{}, attrs)

    case repo.insert(changeset,
           on_conflict: {:replace_all_except, [:id]},
           conflict_target: :id
         ) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, cs} -> {:reply, {:error, changeset_to_error(cs)}, state}
    end
  end

  def handle_call({:get_session, session_id}, _from, %{repo: repo} = state) do
    case repo.get(SessionSchema, session_id) do
      nil ->
        {:reply, {:error, Error.new(:session_not_found, "Session not found: #{session_id}")},
         state}

      schema ->
        {:reply, {:ok, schema_to_session(schema)}, state}
    end
  end

  def handle_call({:list_sessions, opts}, _from, %{repo: repo} = state) do
    sessions =
      from(s in SessionSchema)
      |> maybe_filter(:status, opts)
      |> maybe_filter(:agent_id, opts)
      |> maybe_limit(opts)
      |> repo.all()
      |> Enum.map(&schema_to_session/1)

    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:delete_session, session_id}, _from, %{repo: repo} = state) do
    repo.delete_all(from(s in SessionSchema, where: s.id == ^session_id))
    {:reply, :ok, state}
  end

  # -- Run Operations --

  def handle_call({:save_run, run}, _from, %{repo: repo} = state) do
    attrs = run_to_attrs(run)
    changeset = RunSchema.changeset(%RunSchema{}, attrs)

    case repo.insert(changeset,
           on_conflict: {:replace_all_except, [:id]},
           conflict_target: :id
         ) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, cs} -> {:reply, {:error, changeset_to_error(cs)}, state}
    end
  end

  def handle_call({:get_run, run_id}, _from, %{repo: repo} = state) do
    case repo.get(RunSchema, run_id) do
      nil ->
        {:reply, {:error, Error.new(:run_not_found, "Run not found: #{run_id}")}, state}

      schema ->
        {:reply, {:ok, schema_to_run(schema)}, state}
    end
  end

  def handle_call({:list_runs, session_id, opts}, _from, %{repo: repo} = state) do
    runs =
      from(r in RunSchema, where: r.session_id == ^session_id)
      |> maybe_filter(:status, opts)
      |> maybe_limit(opts)
      |> repo.all()
      |> Enum.map(&schema_to_run/1)

    {:reply, {:ok, runs}, state}
  end

  def handle_call({:get_active_run, session_id}, _from, %{repo: repo} = state) do
    result =
      repo.one(
        from(r in RunSchema,
          where: r.session_id == ^session_id and r.status == "running",
          limit: 1
        )
      )

    case result do
      nil -> {:reply, {:ok, nil}, state}
      schema -> {:reply, {:ok, schema_to_run(schema)}, state}
    end
  end

  # -- Event Operations --

  def handle_call({:append_event, event}, _from, %{repo: repo} = state) do
    case do_append_event_with_sequence(repo, event) do
      {:ok, _stored} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append_event_with_sequence, event}, _from, %{repo: repo} = state) do
    case do_append_event_with_sequence(repo, event) do
      {:ok, stored} -> {:reply, {:ok, stored}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_events, session_id, opts}, _from, %{repo: repo} = state) do
    events =
      from(e in EventSchema,
        where: e.session_id == ^session_id,
        order_by: [asc: e.sequence_number]
      )
      |> maybe_filter(:run_id, opts)
      |> maybe_filter(:type, opts)
      |> maybe_filter(:after, opts)
      |> maybe_filter(:before, opts)
      |> maybe_limit(opts)
      |> repo.all()
      |> Enum.map(&schema_to_event/1)

    {:reply, {:ok, events}, state}
  end

  def handle_call({:get_latest_sequence, session_id}, _from, %{repo: repo} = state) do
    case repo.get(SessionSequenceSchema, session_id) do
      nil -> {:reply, {:ok, 0}, state}
      seq -> {:reply, {:ok, seq.last_sequence}, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp do_append_event_with_sequence(repo, event) do
    repo.transaction(fn ->
      case repo.get(EventSchema, event.id) do
        nil -> insert_event_with_next_sequence(repo, event)
        existing -> schema_to_event(existing)
      end
    end)
  end

  defp insert_event_with_next_sequence(repo, event) do
    next_seq = next_sequence(repo, event.session_id)

    attrs = %{
      id: event.id,
      type: Atom.to_string(event.type),
      timestamp: event.timestamp,
      session_id: event.session_id,
      run_id: event.run_id,
      sequence_number: next_seq,
      data: stringify_keys(event.data),
      metadata: stringify_keys(event.metadata),
      schema_version: event.schema_version || 1,
      provider: event.provider,
      correlation_id: event.correlation_id
    }

    changeset = EventSchema.changeset(%EventSchema{}, attrs)
    repo.insert!(changeset)

    %Event{event | sequence_number: next_seq}
  end

  defp next_sequence(repo, session_id) do
    # Atomic upsert: insert with last_sequence=1, or increment existing.
    # Single statement — no TOCTOU race on PostgreSQL under concurrency.
    on_conflict_query = from(s in SessionSequenceSchema, update: [inc: [last_sequence: 1]])

    {_count, [%{last_sequence: seq}]} =
      repo.insert_all(
        SessionSequenceSchema,
        [%{session_id: session_id, last_sequence: 1}],
        on_conflict: on_conflict_query,
        conflict_target: :session_id,
        returning: [:last_sequence]
      )

    seq
  end

  # -- Composable query filters --

  defp maybe_filter(query, :status, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      status -> from(q in query, where: q.status == ^Atom.to_string(status))
    end
  end

  defp maybe_filter(query, :agent_id, opts) do
    case Keyword.get(opts, :agent_id) do
      nil -> query
      agent_id -> from(q in query, where: q.agent_id == ^agent_id)
    end
  end

  defp maybe_filter(query, :run_id, opts) do
    case Keyword.get(opts, :run_id) do
      nil -> query
      run_id -> from(q in query, where: q.run_id == ^run_id)
    end
  end

  defp maybe_filter(query, :type, opts) do
    case Keyword.get(opts, :type) do
      nil -> query
      type -> from(q in query, where: q.type == ^Atom.to_string(type))
    end
  end

  defp maybe_filter(query, :after, opts) do
    case Keyword.get(opts, :after) do
      nil -> query
      seq -> from(q in query, where: q.sequence_number > ^seq)
    end
  end

  defp maybe_filter(query, :before, opts) do
    case Keyword.get(opts, :before) do
      nil -> query
      seq -> from(q in query, where: q.sequence_number < ^seq)
    end
  end

  defp maybe_limit(query, opts) do
    case Keyword.get(opts, :limit) do
      nil -> query
      n when is_integer(n) -> from(q in query, limit: ^n)
    end
  end

  # -- Core struct <-> Schema attrs conversion --

  defp session_to_attrs(%Session{} = s) do
    %{
      id: s.id,
      agent_id: s.agent_id,
      status: Atom.to_string(s.status),
      parent_session_id: s.parent_session_id,
      metadata: stringify_keys(s.metadata || %{}),
      context: stringify_keys(s.context || %{}),
      tags: s.tags || [],
      created_at: s.created_at,
      updated_at: s.updated_at,
      deleted_at: s.deleted_at
    }
  end

  defp schema_to_session(%SessionSchema{} = s) do
    %Session{
      id: s.id,
      agent_id: s.agent_id,
      status: safe_to_atom(s.status),
      parent_session_id: s.parent_session_id,
      metadata: atomize_keys(s.metadata || %{}),
      context: atomize_keys(s.context || %{}),
      tags: s.tags || [],
      created_at: s.created_at,
      updated_at: s.updated_at,
      deleted_at: s.deleted_at
    }
  end

  defp run_to_attrs(%Run{} = r) do
    %{
      id: r.id,
      session_id: r.session_id,
      status: Atom.to_string(r.status),
      input: stringify_keys(r.input),
      output: stringify_keys(r.output),
      error: stringify_keys(r.error),
      metadata: stringify_keys(r.metadata || %{}),
      turn_count: r.turn_count || 0,
      token_usage: stringify_keys(r.token_usage || %{}),
      started_at: r.started_at,
      ended_at: r.ended_at,
      provider: r.provider,
      provider_metadata: stringify_keys(r.provider_metadata || %{})
    }
  end

  defp schema_to_run(%RunSchema{} = r) do
    %Run{
      id: r.id,
      session_id: r.session_id,
      status: safe_to_atom(r.status),
      input: atomize_keys_nullable(r.input),
      output: atomize_keys_nullable(r.output),
      error: atomize_keys_nullable(r.error),
      metadata: atomize_keys(r.metadata || %{}),
      turn_count: r.turn_count || 0,
      token_usage: atomize_keys(r.token_usage || %{}),
      started_at: r.started_at,
      ended_at: r.ended_at,
      provider: r.provider,
      provider_metadata: atomize_keys(r.provider_metadata || %{})
    }
  end

  defp schema_to_event(%EventSchema{} = e) do
    %Event{
      id: e.id,
      type: safe_to_atom(e.type),
      timestamp: e.timestamp,
      session_id: e.session_id,
      run_id: e.run_id,
      sequence_number: e.sequence_number,
      data: atomize_keys(e.data || %{}),
      metadata: atomize_keys(e.metadata || %{}),
      schema_version: e.schema_version || 1,
      provider: e.provider,
      correlation_id: e.correlation_id
    }
  end

  # -- Map key helpers --

  defp stringify_keys(nil), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  defp atomize_keys_nullable(nil), do: nil
  defp atomize_keys_nullable(val), do: atomize_keys(val)

  defp safe_to_atom(val) when is_binary(val), do: String.to_existing_atom(val)
  defp safe_to_atom(val) when is_atom(val), do: val

  defp changeset_to_error(changeset) do
    message =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
      |> inspect()

    Error.new(:validation_error, message)
  end
end
