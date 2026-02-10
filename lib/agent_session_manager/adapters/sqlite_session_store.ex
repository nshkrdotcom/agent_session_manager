defmodule AgentSessionManager.Adapters.SQLiteSessionStore do
  @moduledoc """
  SQLite-backed session store using ecto_sqlite3.

  Stores sessions, runs, and events in a local SQLite database file.
  Ideal for single-node deployments, CLI tools, and development environments.

  ## Features

  - WAL mode for concurrent read access during writes
  - Single-writer model ensures atomic sequence assignment
  - Automatic schema bootstrap on startup
  - Full SessionStore behaviour compliance

  ## Usage

      {:ok, store} = SQLiteSessionStore.start_link(path: "/tmp/sessions.db")

      SessionStore.save_session(store, session)
      {:ok, session} = SessionStore.get_session(store, session_id)

  ## Options

  - `:path` - Required. Path to the SQLite database file.
  - `:name` - Optional. GenServer name for registration.
  """

  @behaviour AgentSessionManager.Ports.SessionStore

  use GenServer

  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  # ============================================================================
  # Client API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" ->
        {name, remaining} = Keyword.pop(opts, :name)

        if name do
          GenServer.start_link(__MODULE__, remaining, name: name)
        else
          GenServer.start_link(__MODULE__, remaining)
        end

      _ ->
        {:error, Error.new(:validation_error, "path is required")}
    end
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ============================================================================
  # SessionStore Behaviour Implementation
  # ============================================================================

  @impl SessionStore
  def save_session(store, %Session{} = session) do
    GenServer.call(store, {:save_session, session})
  end

  @impl SessionStore
  def get_session(store, session_id) do
    GenServer.call(store, {:get_session, session_id})
  end

  @impl SessionStore
  def list_sessions(store, opts \\ []) do
    GenServer.call(store, {:list_sessions, opts})
  end

  @impl SessionStore
  def delete_session(store, session_id) do
    GenServer.call(store, {:delete_session, session_id})
  end

  @impl SessionStore
  def save_run(store, %Run{} = run) do
    GenServer.call(store, {:save_run, run})
  end

  @impl SessionStore
  def get_run(store, run_id) do
    GenServer.call(store, {:get_run, run_id})
  end

  @impl SessionStore
  def list_runs(store, session_id, opts \\ []) do
    GenServer.call(store, {:list_runs, session_id, opts})
  end

  @impl SessionStore
  def get_active_run(store, session_id) do
    GenServer.call(store, {:get_active_run, session_id})
  end

  @impl SessionStore
  def append_event(store, %Event{} = event) do
    GenServer.call(store, {:append_event, event})
  end

  @impl SessionStore
  def append_event_with_sequence(store, %Event{} = event) do
    GenServer.call(store, {:append_event_with_sequence, event})
  end

  @impl SessionStore
  def get_events(store, session_id, opts \\ []) do
    GenServer.call(store, {:get_events, session_id, opts})
  end

  @impl SessionStore
  def get_latest_sequence(store, session_id) do
    GenServer.call(store, {:get_latest_sequence, session_id})
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path) |> Path.expand()

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case Exqlite.Sqlite3.open(path) do
          {:ok, conn} ->
            bootstrap_schema(conn)
            {:ok, %{conn: conn, path: path}}

          {:error, reason} ->
            {:stop,
             Error.new(:storage_error, "Failed to open SQLite database: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:stop, Error.new(:storage_error, "Failed to create directory: #{inspect(reason)}")}
    end
  end

  @impl GenServer
  def handle_call({:save_session, session}, _from, state) do
    sql = """
    INSERT INTO asm_sessions (id, agent_id, status, parent_session_id, metadata, context, tags, created_at, updated_at, deleted_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
    ON CONFLICT(id) DO UPDATE SET
      agent_id = excluded.agent_id,
      status = excluded.status,
      parent_session_id = excluded.parent_session_id,
      metadata = excluded.metadata,
      context = excluded.context,
      tags = excluded.tags,
      updated_at = excluded.updated_at,
      deleted_at = excluded.deleted_at
    """

    params = [
      session.id,
      session.agent_id,
      Atom.to_string(session.status),
      session.parent_session_id,
      Jason.encode!(session.metadata),
      Jason.encode!(session.context),
      Jason.encode!(session.tags),
      format_datetime(session.created_at),
      format_datetime(session.updated_at),
      format_optional_datetime(session.deleted_at)
    ]

    case execute(state.conn, sql, params) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, storage_error(reason)}, state}
    end
  end

  def handle_call({:get_session, session_id}, _from, state) do
    sql = "SELECT * FROM asm_sessions WHERE id = ?1"

    case query_one(state.conn, sql, [session_id]) do
      {:ok, row} ->
        {:reply, {:ok, row_to_session(row)}, state}

      :not_found ->
        {:reply, {:error, Error.new(:session_not_found, "Session not found: #{session_id}")},
         state}
    end
  end

  def handle_call({:list_sessions, opts}, _from, state) do
    {where_clauses, params} = build_session_filters(opts)

    sql =
      "SELECT * FROM asm_sessions" <>
        build_where(where_clauses) <>
        build_limit(opts)

    {:ok, rows} = query_all(state.conn, sql, params)
    sessions = Enum.map(rows, &row_to_session/1)
    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    execute(state.conn, "DELETE FROM asm_sessions WHERE id = ?1", [session_id])
    {:reply, :ok, state}
  end

  def handle_call({:save_run, run}, _from, state) do
    sql = """
    INSERT INTO asm_runs (id, session_id, status, input, output, error, metadata, turn_count, token_usage, started_at, ended_at, provider, provider_metadata)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
    ON CONFLICT(id) DO UPDATE SET
      session_id = excluded.session_id,
      status = excluded.status,
      input = excluded.input,
      output = excluded.output,
      error = excluded.error,
      metadata = excluded.metadata,
      turn_count = excluded.turn_count,
      token_usage = excluded.token_usage,
      started_at = excluded.started_at,
      ended_at = excluded.ended_at,
      provider = excluded.provider,
      provider_metadata = excluded.provider_metadata
    """

    params = [
      run.id,
      run.session_id,
      Atom.to_string(run.status),
      encode_json(run.input),
      encode_json(run.output),
      encode_json(run.error),
      Jason.encode!(run.metadata),
      run.turn_count,
      Jason.encode!(run.token_usage),
      format_datetime(run.started_at),
      format_optional_datetime(run.ended_at),
      run.provider,
      Jason.encode!(run.provider_metadata || %{})
    ]

    case execute(state.conn, sql, params) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, storage_error(reason)}, state}
    end
  end

  def handle_call({:get_run, run_id}, _from, state) do
    sql = "SELECT * FROM asm_runs WHERE id = ?1"

    case query_one(state.conn, sql, [run_id]) do
      {:ok, row} ->
        {:reply, {:ok, row_to_run(row)}, state}

      :not_found ->
        {:reply, {:error, Error.new(:run_not_found, "Run not found: #{run_id}")}, state}
    end
  end

  def handle_call({:list_runs, session_id, opts}, _from, state) do
    {where_clauses, params} = build_run_filters(session_id, opts)

    sql =
      "SELECT * FROM asm_runs" <>
        build_where(where_clauses) <>
        build_limit(opts)

    {:ok, rows} = query_all(state.conn, sql, params)
    runs = Enum.map(rows, &row_to_run/1)
    {:reply, {:ok, runs}, state}
  end

  def handle_call({:get_active_run, session_id}, _from, state) do
    sql = "SELECT * FROM asm_runs WHERE session_id = ?1 AND status = 'running' LIMIT 1"

    case query_one(state.conn, sql, [session_id]) do
      {:ok, row} -> {:reply, {:ok, row_to_run(row)}, state}
      :not_found -> {:reply, {:ok, nil}, state}
    end
  end

  def handle_call({:append_event, event}, _from, state) do
    case do_append_event_with_sequence(state.conn, event) do
      {:ok, _stored} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append_event_with_sequence, event}, _from, state) do
    case do_append_event_with_sequence(state.conn, event) do
      {:ok, stored} -> {:reply, {:ok, stored}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_events, session_id, opts}, _from, state) do
    {where_clauses, params} = build_event_filters(session_id, opts)

    sql =
      "SELECT * FROM asm_events" <>
        build_where(where_clauses) <>
        " ORDER BY sequence_number ASC" <>
        build_limit(opts)

    {:ok, rows} = query_all(state.conn, sql, params)
    events = Enum.map(rows, &row_to_event/1)
    {:reply, {:ok, events}, state}
  end

  def handle_call({:get_latest_sequence, session_id}, _from, state) do
    sql = "SELECT last_sequence FROM asm_session_sequences WHERE session_id = ?1"

    case query_one(state.conn, sql, [session_id]) do
      {:ok, row} ->
        [seq] = row
        {:reply, {:ok, seq}, state}

      :not_found ->
        {:reply, {:ok, 0}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    Exqlite.Sqlite3.close(state.conn)
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp bootstrap_schema(conn) do
    pragmas = [
      "PRAGMA journal_mode=WAL",
      "PRAGMA synchronous=NORMAL",
      "PRAGMA foreign_keys=ON",
      "PRAGMA busy_timeout=5000"
    ]

    tables = [
      """
      CREATE TABLE IF NOT EXISTS asm_sessions (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        status TEXT NOT NULL,
        parent_session_id TEXT NULL,
        metadata TEXT DEFAULT '{}',
        context TEXT DEFAULT '{}',
        tags TEXT DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS asm_runs (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        status TEXT NOT NULL,
        input TEXT NULL,
        output TEXT NULL,
        error TEXT NULL,
        metadata TEXT DEFAULT '{}',
        turn_count INTEGER DEFAULT 0,
        token_usage TEXT DEFAULT '{}',
        started_at TEXT NOT NULL,
        ended_at TEXT NULL,
        provider TEXT NULL,
        provider_metadata TEXT DEFAULT '{}'
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS asm_events (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        session_id TEXT NOT NULL,
        run_id TEXT NULL,
        sequence_number INTEGER NOT NULL,
        data TEXT DEFAULT '{}',
        metadata TEXT DEFAULT '{}',
        schema_version INTEGER NOT NULL DEFAULT 1,
        provider TEXT NULL,
        correlation_id TEXT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS asm_session_sequences (
        session_id TEXT PRIMARY KEY,
        last_sequence INTEGER DEFAULT 0,
        updated_at TEXT NOT NULL
      )
      """
    ]

    artifacts_table = [
      """
      CREATE TABLE IF NOT EXISTS asm_artifacts (
        id TEXT PRIMARY KEY,
        session_id TEXT NULL,
        run_id TEXT NULL,
        key TEXT NOT NULL UNIQUE,
        content_type TEXT NULL,
        byte_size INTEGER NOT NULL,
        checksum_sha256 TEXT NOT NULL,
        storage_backend TEXT NOT NULL,
        storage_ref TEXT NOT NULL,
        metadata TEXT DEFAULT '{}',
        created_at TEXT NOT NULL,
        deleted_at TEXT NULL
      )
      """
    ]

    indexes = [
      "CREATE INDEX IF NOT EXISTS idx_sessions_status ON asm_sessions(status)",
      "CREATE INDEX IF NOT EXISTS idx_sessions_agent_id ON asm_sessions(agent_id)",
      "CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON asm_sessions(created_at)",
      "CREATE INDEX IF NOT EXISTS idx_sessions_deleted_at ON asm_sessions(deleted_at)",
      "CREATE INDEX IF NOT EXISTS idx_runs_session_id ON asm_runs(session_id)",
      "CREATE INDEX IF NOT EXISTS idx_runs_session_status ON asm_runs(session_id, status)",
      "CREATE INDEX IF NOT EXISTS idx_runs_provider ON asm_runs(provider)",
      "CREATE INDEX IF NOT EXISTS idx_runs_started_at ON asm_runs(started_at)",
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_seq ON asm_events(session_id, sequence_number)",
      "CREATE INDEX IF NOT EXISTS idx_events_session_type ON asm_events(session_id, type, sequence_number)",
      "CREATE INDEX IF NOT EXISTS idx_events_session_run ON asm_events(session_id, run_id, sequence_number)",
      "CREATE INDEX IF NOT EXISTS idx_events_correlation_id ON asm_events(correlation_id)",
      "CREATE INDEX IF NOT EXISTS idx_events_provider ON asm_events(provider)",
      "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON asm_events(timestamp)",
      "CREATE INDEX IF NOT EXISTS idx_artifacts_session_id ON asm_artifacts(session_id)",
      "CREATE INDEX IF NOT EXISTS idx_artifacts_created_at ON asm_artifacts(created_at)"
    ]

    for sql <- pragmas ++ tables ++ artifacts_table ++ indexes do
      execute!(conn, sql)
    end
  end

  defp do_append_event_with_sequence(conn, %Event{} = event) do
    # Check for duplicate by event ID
    case query_one(conn, "SELECT * FROM asm_events WHERE id = ?1", [event.id]) do
      {:ok, row} ->
        # Idempotent: return existing event
        {:ok, row_to_event(row)}

      :not_found ->
        # Atomic sequence assignment inside BEGIN IMMEDIATE
        execute!(conn, "BEGIN IMMEDIATE")

        try do
          # Ensure session_sequences row exists
          execute!(
            conn,
            "INSERT OR IGNORE INTO asm_session_sequences (session_id, last_sequence, updated_at) VALUES (?1, 0, ?2)",
            [event.session_id, format_datetime(DateTime.utc_now())]
          )

          # Get current sequence
          {:ok, [last_seq]} =
            query_one(
              conn,
              "SELECT last_sequence FROM asm_session_sequences WHERE session_id = ?1",
              [event.session_id]
            )

          next_seq = last_seq + 1

          # Insert event
          execute!(
            conn,
            """
              INSERT INTO asm_events (id, type, timestamp, session_id, run_id, sequence_number, data, metadata, schema_version, provider, correlation_id)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            """,
            [
              event.id,
              Atom.to_string(event.type),
              format_datetime(event.timestamp),
              event.session_id,
              event.run_id,
              next_seq,
              Jason.encode!(event.data),
              Jason.encode!(event.metadata),
              event.schema_version || 1,
              event.provider,
              event.correlation_id
            ]
          )

          # Update sequence counter
          execute!(
            conn,
            "UPDATE asm_session_sequences SET last_sequence = ?1, updated_at = ?2 WHERE session_id = ?3",
            [next_seq, format_datetime(DateTime.utc_now()), event.session_id]
          )

          execute!(conn, "COMMIT")

          {:ok, %{event | sequence_number: next_seq}}
        rescue
          e ->
            execute!(conn, "ROLLBACK")
            {:error, Error.new(:storage_write_failed, "Failed to append event: #{inspect(e)}")}
        end
    end
  end

  # SQL execution helpers

  defp execute(conn, sql) do
    Exqlite.Sqlite3.execute(conn, sql)
  end

  defp execute(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      step_until_done(conn, stmt)
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp execute!(conn, sql) do
    :ok = execute(conn, sql)
  end

  defp execute!(conn, sql, params) do
    :ok = execute(conn, sql, params)
  end

  defp step_until_done(conn, stmt) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _row} -> step_until_done(conn, stmt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp query_one(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)

      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, row} -> {:ok, row}
        :done -> :not_found
      end
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp query_all(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      {:ok, rows}
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  # Row-to-struct converters

  defp row_to_session([
         id,
         agent_id,
         status,
         parent_session_id,
         metadata,
         context,
         tags,
         created_at,
         updated_at,
         deleted_at
       ]) do
    %Session{
      id: id,
      agent_id: agent_id,
      status: safe_to_atom(status),
      parent_session_id: parent_session_id,
      metadata: decode_json_map(metadata),
      context: decode_json_map(context),
      tags: decode_json_list(tags),
      created_at: parse_datetime!(created_at),
      updated_at: parse_datetime!(updated_at),
      deleted_at: parse_optional_datetime(deleted_at)
    }
  end

  defp row_to_run([
         id,
         session_id,
         status,
         input,
         output,
         error,
         metadata,
         turn_count,
         token_usage,
         started_at,
         ended_at,
         provider,
         provider_metadata
       ]) do
    %Run{
      id: id,
      session_id: session_id,
      status: safe_to_atom(status),
      input: decode_json_nullable(input),
      output: decode_json_nullable(output),
      error: decode_json_nullable(error),
      metadata: decode_json_map(metadata),
      turn_count: turn_count || 0,
      token_usage: decode_json_map(token_usage),
      started_at: parse_datetime!(started_at),
      ended_at: parse_optional_datetime(ended_at),
      provider: provider,
      provider_metadata: decode_json_map(provider_metadata)
    }
  end

  defp row_to_event([
         id,
         type,
         timestamp,
         session_id,
         run_id,
         sequence_number,
         data,
         metadata,
         schema_version,
         provider,
         correlation_id
       ]) do
    %Event{
      id: id,
      type: safe_to_atom(type),
      timestamp: parse_datetime!(timestamp),
      session_id: session_id,
      run_id: run_id,
      sequence_number: sequence_number,
      data: decode_json_map(data),
      metadata: decode_json_map(metadata),
      schema_version: schema_version || 1,
      provider: provider,
      correlation_id: correlation_id
    }
  end

  # Filter builders

  defp build_session_filters(opts) do
    {clauses, params, _idx} =
      Enum.reduce(
        [{:status, Keyword.get(opts, :status)}, {:agent_id, Keyword.get(opts, :agent_id)}],
        {[], [], 1},
        fn
          {_key, nil}, acc ->
            acc

          {:status, status}, {clauses, params, idx} ->
            {clauses ++ ["status = ?#{idx}"], params ++ [Atom.to_string(status)], idx + 1}

          {:agent_id, agent_id}, {clauses, params, idx} ->
            {clauses ++ ["agent_id = ?#{idx}"], params ++ [agent_id], idx + 1}
        end
      )

    {clauses, params}
  end

  defp build_run_filters(session_id, opts) do
    base_clauses = ["session_id = ?1"]
    base_params = [session_id]

    case Keyword.get(opts, :status) do
      nil ->
        {base_clauses, base_params}

      status ->
        {base_clauses ++ ["status = ?2"], base_params ++ [Atom.to_string(status)]}
    end
  end

  defp build_event_filters(session_id, opts) do
    {clauses, params, _idx} =
      Enum.reduce(
        [
          {:run_id, Keyword.get(opts, :run_id)},
          {:type, Keyword.get(opts, :type)},
          {:after, Keyword.get(opts, :after)},
          {:before, Keyword.get(opts, :before)}
        ],
        {["session_id = ?1"], [session_id], 2},
        fn
          {_key, nil}, acc ->
            acc

          {:run_id, run_id}, {clauses, params, idx} ->
            {clauses ++ ["run_id = ?#{idx}"], params ++ [run_id], idx + 1}

          {:type, type}, {clauses, params, idx} ->
            {clauses ++ ["type = ?#{idx}"], params ++ [Atom.to_string(type)], idx + 1}

          {:after, after_cursor}, {clauses, params, idx} when is_integer(after_cursor) ->
            {clauses ++ ["sequence_number > ?#{idx}"], params ++ [after_cursor], idx + 1}

          {:before, before_cursor}, {clauses, params, idx} when is_integer(before_cursor) ->
            {clauses ++ ["sequence_number < ?#{idx}"], params ++ [before_cursor], idx + 1}

          _, acc ->
            acc
        end
      )

    {clauses, params}
  end

  defp build_where([]), do: ""
  defp build_where(clauses), do: " WHERE " <> Enum.join(clauses, " AND ")

  defp build_limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> ""
      limit when is_integer(limit) and limit > 0 -> " LIMIT #{limit}"
      _ -> ""
    end
  end

  # JSON helpers

  defp encode_json(nil), do: nil
  defp encode_json(map) when is_map(map), do: Jason.encode!(map)

  defp decode_json_map(nil), do: %{}
  defp decode_json_map(str) when is_binary(str), do: Jason.decode!(str) |> atomize_keys()

  defp decode_json_list(nil), do: []
  defp decode_json_list(str) when is_binary(str), do: Jason.decode!(str)

  defp decode_json_nullable(nil), do: nil
  defp decode_json_nullable(str) when is_binary(str), do: Jason.decode!(str) |> atomize_keys()

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  # DateTime helpers

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(nil), do: nil

  defp format_optional_datetime(nil), do: nil
  defp format_optional_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime!(str) when is_binary(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end

  defp parse_optional_datetime(nil), do: nil
  defp parse_optional_datetime(str) when is_binary(str), do: parse_datetime!(str)

  defp safe_to_atom(str) when is_binary(str), do: String.to_existing_atom(str)

  defp storage_error(reason) do
    Error.new(:storage_error, "SQLite error: #{inspect(reason)}")
  end
end
