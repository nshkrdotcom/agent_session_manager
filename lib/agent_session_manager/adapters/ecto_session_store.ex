if Code.ensure_loaded?(Ecto.Query) do
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

    alias AgentSessionManager.Core.{Error, Event, Run, Serialization, Session}
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
    def append_events(store, events), do: GenServer.call(store, {:append_events, events})

    @impl SessionStore
    def flush(store, execution_result), do: GenServer.call(store, {:flush, execution_result})

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
      case do_save_session(repo, session) do
        {:ok, _} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
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
      case do_save_run(repo, run) do
        {:ok, _} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
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

    def handle_call({:append_events, events}, _from, %{repo: repo} = state) do
      case do_append_events_with_sequence(repo, events) do
        {:ok, stored_events} -> {:reply, {:ok, stored_events}, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:flush, execution_result}, _from, %{repo: repo} = state) do
      case do_flush(repo, execution_result) do
        :ok -> {:reply, :ok, state}
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
        |> maybe_filter(:since, opts)
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

    defp do_append_events_with_sequence(repo, events) when is_list(events) do
      result =
        repo.transaction(fn ->
          case append_events_with_sequence_in_tx(repo, events) do
            {:ok, stored_events} -> stored_events
            {:error, reason} -> repo.rollback(reason)
          end
        end)

      case result do
        {:ok, stored_events} ->
          {:ok, stored_events}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, Error.new(:storage_error, "Failed to append events: #{inspect(reason)}")}
      end
    end

    defp do_append_events_with_sequence(_repo, _events) do
      {:error, Error.new(:validation_error, "events must be a list")}
    end

    defp do_flush(
           repo,
           %{session: %Session{} = session, run: %Run{} = run, events: events}
         )
         when is_list(events) do
      result =
        repo.transaction(fn ->
          with {:ok, _} <- do_save_session(repo, session),
               {:ok, _} <- do_save_run(repo, run),
               {:ok, _stored_events} <- append_events_with_sequence_in_tx(repo, events) do
            :ok
          else
            {:error, reason} -> repo.rollback(reason)
          end
        end)

      case result do
        {:ok, :ok} ->
          :ok

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, Error.new(:storage_error, "flush failed: #{inspect(reason)}")}
      end
    end

    defp do_flush(_repo, _payload) do
      {:error, Error.new(:validation_error, "invalid execution_result payload")}
    end

    defp append_events_with_sequence_in_tx(repo, events) do
      if Enum.all?(events, &match?(%Event{}, &1)) do
        append_valid_events_with_sequence_in_tx(repo, events)
      else
        {:error, Error.new(:validation_error, "events must be Event structs")}
      end
    end

    defp append_valid_events_with_sequence_in_tx(_repo, []), do: {:ok, []}

    defp append_valid_events_with_sequence_in_tx(repo, events) do
      unique_events = unique_events_by_id(events)
      unique_ids = Enum.map(unique_events, & &1.id)

      existing_events_by_id =
        repo.all(from(e in EventSchema, where: e.id in ^unique_ids))
        |> Enum.map(&schema_to_event/1)
        |> Map.new(fn event -> {event.id, event} end)

      new_events =
        Enum.reject(unique_events, fn event ->
          Map.has_key?(existing_events_by_id, event.id)
        end)

      with {:ok, inserted_events_by_id} <- insert_new_events_with_sequences(repo, new_events) do
        persisted_events_by_id = Map.merge(existing_events_by_id, inserted_events_by_id)
        {:ok, Enum.map(events, fn event -> Map.fetch!(persisted_events_by_id, event.id) end)}
      end
    end

    defp insert_new_events_with_sequences(_repo, []), do: {:ok, %{}}

    defp insert_new_events_with_sequences(repo, events) do
      grouped_by_session = Enum.group_by(events, & &1.session_id)

      Enum.reduce_while(grouped_by_session, {:ok, %{}}, fn {session_id, session_events},
                                                           {:ok, acc} ->
        case insert_session_events_batch(repo, session_id, session_events) do
          {:ok, inserted} -> {:cont, {:ok, Map.merge(acc, inserted)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    defp insert_session_events_batch(repo, session_id, session_events) do
      base_sequence = next_sequence_batch(repo, session_id, length(session_events))

      rows =
        Enum.with_index(session_events, fn event, index ->
          event_to_attrs_with_sequence(event, base_sequence + index)
        end)

      case repo.insert_all(EventSchema, rows) do
        {count, _} when count == length(rows) ->
          inserted =
            Enum.with_index(session_events, fn event, index ->
              {event.id, %Event{event | sequence_number: base_sequence + index}}
            end)
            |> Map.new()

          {:ok, inserted}

        {count, _} ->
          {:error,
           Error.new(
             :storage_error,
             "batch insert count mismatch for session #{session_id}: expected #{length(rows)}, got #{count}"
           )}
      end
    end

    defp insert_event_with_next_sequence(repo, event) do
      next_seq = next_sequence(repo, event.session_id)

      attrs = event_to_attrs_with_sequence(event, next_seq)

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

    defp next_sequence_batch(repo, session_id, count) when is_integer(count) and count > 0 do
      on_conflict_query =
        from(s in SessionSequenceSchema, update: [inc: [last_sequence: ^count]])

      {_count, [%{last_sequence: last_seq}]} =
        repo.insert_all(
          SessionSequenceSchema,
          [%{session_id: session_id, last_sequence: count}],
          on_conflict: on_conflict_query,
          conflict_target: :session_id,
          returning: [:last_sequence]
        )

      last_seq - count + 1
    end

    defp unique_events_by_id(events) do
      {_, unique_reversed} =
        Enum.reduce(events, {MapSet.new(), []}, fn event, {seen_ids, acc} ->
          if MapSet.member?(seen_ids, event.id) do
            {seen_ids, acc}
          else
            {MapSet.put(seen_ids, event.id), [event | acc]}
          end
        end)

      Enum.reverse(unique_reversed)
    end

    defp do_save_session(repo, session) do
      attrs = session_to_attrs(session)
      changeset = SessionSchema.changeset(%SessionSchema{}, attrs)

      case repo.insert(changeset,
             on_conflict: {:replace_all_except, [:id]},
             conflict_target: :id
           ) do
        {:ok, schema} -> {:ok, schema}
        {:error, cs} -> {:error, changeset_to_error(cs)}
      end
    end

    defp do_save_run(repo, run) do
      attrs = run_to_attrs(run)
      changeset = RunSchema.changeset(%RunSchema{}, attrs)

      case repo.insert(changeset,
             on_conflict: {:replace_all_except, [:id]},
             conflict_target: :id
           ) do
        {:ok, schema} -> {:ok, schema}
        {:error, cs} -> {:error, changeset_to_error(cs)}
      end
    end

    defp event_to_attrs_with_sequence(event, sequence_number) do
      %{
        id: event.id,
        type: Atom.to_string(event.type),
        timestamp: event.timestamp,
        session_id: event.session_id,
        run_id: event.run_id,
        sequence_number: sequence_number,
        data: stringify_keys(event.data),
        metadata: stringify_keys(event.metadata),
        schema_version: event.schema_version || 1,
        provider: event.provider,
        correlation_id: event.correlation_id
      }
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

    defp maybe_filter(query, :since, opts) do
      case Keyword.get(opts, :since) do
        nil -> query
        %DateTime{} = since -> from(q in query, where: q.timestamp > ^since)
        since -> from(q in query, where: q.timestamp > ^since)
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

    defp stringify_keys(value), do: Serialization.stringify_keys(value)
    defp atomize_keys(value), do: Serialization.atomize_keys(value)

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
else
  defmodule AgentSessionManager.Adapters.EctoSessionStore do
    @moduledoc """
    Fallback implementation used when optional Ecto dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.SessionStore

    alias AgentSessionManager.OptionalDependency
    alias AgentSessionManager.Ports.SessionStore

    @spec start_link(keyword()) :: {:error, AgentSessionManager.Core.Error.t()}
    def start_link(_opts) do
      {:error, missing_dependency_error(:start_link)}
    end

    @impl SessionStore
    def save_session(_store, _session), do: {:error, missing_dependency_error(:save_session)}

    @impl SessionStore
    def get_session(_store, _session_id), do: {:error, missing_dependency_error(:get_session)}

    @impl SessionStore
    def list_sessions(_store, _opts \\ []), do: {:error, missing_dependency_error(:list_sessions)}

    @impl SessionStore
    def delete_session(_store, _session_id),
      do: {:error, missing_dependency_error(:delete_session)}

    @impl SessionStore
    def save_run(_store, _run), do: {:error, missing_dependency_error(:save_run)}

    @impl SessionStore
    def get_run(_store, _run_id), do: {:error, missing_dependency_error(:get_run)}

    @impl SessionStore
    def list_runs(_store, _session_id, _opts \\ []),
      do: {:error, missing_dependency_error(:list_runs)}

    @impl SessionStore
    def get_active_run(_store, _session_id),
      do: {:error, missing_dependency_error(:get_active_run)}

    @impl SessionStore
    def append_event(_store, _event), do: {:error, missing_dependency_error(:append_event)}

    @impl SessionStore
    def append_event_with_sequence(_store, _event),
      do: {:error, missing_dependency_error(:append_event_with_sequence)}

    @impl SessionStore
    def append_events(_store, _events), do: {:error, missing_dependency_error(:append_events)}

    @impl SessionStore
    def flush(_store, _execution_result), do: {:error, missing_dependency_error(:flush)}

    @impl SessionStore
    def get_events(_store, _session_id, _opts \\ []),
      do: {:error, missing_dependency_error(:get_events)}

    @impl SessionStore
    def get_latest_sequence(_store, _session_id),
      do: {:error, missing_dependency_error(:get_latest_sequence)}

    defp missing_dependency_error(operation) do
      OptionalDependency.error(:ecto_sql, __MODULE__, operation)
    end
  end
end
