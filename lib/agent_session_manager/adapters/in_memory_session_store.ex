defmodule AgentSessionManager.Adapters.InMemorySessionStore do
  @moduledoc """
  In-memory implementation of the SessionStore behaviour.

  This adapter stores all session data in memory using a GenServer with
  ETS tables for efficient concurrent reads. It is designed primarily
  for testing and development environments.

  ## Design

  - Uses ETS tables for concurrent read access
  - GenServer handles writes to ensure consistency
  - Events are stored in an append-only log with preserved order
  - All writes are idempotent (same ID updates, doesn't duplicate)
  - Thread-safe for concurrent access

  ## Data Structures

  - Sessions: ETS table keyed by session_id
  - Runs: ETS table keyed by run_id with session_id index
  - Events: Append-only list stored in GenServer state (maintains order)
    - Also indexed in ETS by event_id for deduplication

  ## Usage

      {:ok, store} = InMemorySessionStore.start_link([])

      # Use via SessionStore port
      SessionStore.save_session(store, session)
      {:ok, session} = SessionStore.get_session(store, session_id)

  ## Options

  - `:name` - Optional name for the GenServer (default: none)

  """

  use GenServer

  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  @behaviour SessionStore

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the in-memory session store.

  ## Options

  - `:name` - Optional name to register the GenServer

  ## Examples

      {:ok, store} = InMemorySessionStore.start_link([])
      {:ok, store} = InMemorySessionStore.start_link(name: :my_store)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Stops the session store.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

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
  def append_events(store, events) when is_list(events) do
    GenServer.call(store, {:append_events, events})
  end

  @impl SessionStore
  def flush(store, execution_result) when is_map(execution_result) do
    GenServer.call(store, {:flush, execution_result})
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
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(_opts) do
    # Create ETS tables for efficient concurrent reads
    sessions_table = :ets.new(:sessions, [:set, :protected, read_concurrency: true])
    runs_table = :ets.new(:runs, [:set, :protected, read_concurrency: true])
    event_ids_table = :ets.new(:event_ids, [:set, :protected, read_concurrency: true])

    state = %{
      sessions: sessions_table,
      runs: runs_table,
      event_ids: event_ids_table,
      # Append-only event log queue - preserves insertion order with O(1) appends
      events: :queue.new(),
      # Latest assigned sequence number per session_id
      session_sequences: %{},
      # Waiters for long-poll: [{from, session_id, opts, timer_ref}]
      waiters: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:save_session, session}, _from, state) do
    :ets.insert(state.sessions, {session.id, session})
    {:reply, :ok, state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case :ets.lookup(state.sessions, session_id) do
      [{^session_id, session}] ->
        {:reply, {:ok, session}, state}

      [] ->
        error = Error.new(:session_not_found, "Session not found: #{session_id}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list_sessions, opts}, _from, state) do
    sessions =
      :ets.tab2list(state.sessions)
      |> Enum.map(fn {_id, session} -> session end)
      |> filter_sessions(opts)

    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    :ets.delete(state.sessions, session_id)
    {:reply, :ok, state}
  end

  def handle_call({:save_run, run}, _from, state) do
    :ets.insert(state.runs, {run.id, run})
    {:reply, :ok, state}
  end

  def handle_call({:get_run, run_id}, _from, state) do
    case :ets.lookup(state.runs, run_id) do
      [{^run_id, run}] ->
        {:reply, {:ok, run}, state}

      [] ->
        error = Error.new(:run_not_found, "Run not found: #{run_id}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list_runs, session_id, opts}, _from, state) do
    runs =
      :ets.tab2list(state.runs)
      |> Enum.map(fn {_id, run} -> run end)
      |> Enum.filter(&(&1.session_id == session_id))
      |> filter_runs(opts)

    {:reply, {:ok, runs}, state}
  end

  def handle_call({:get_active_run, session_id}, _from, state) do
    active_run =
      :ets.tab2list(state.runs)
      |> Enum.map(fn {_id, run} -> run end)
      |> Enum.find(&(&1.session_id == session_id && &1.status == :running))

    {:reply, {:ok, active_run}, state}
  end

  def handle_call({:append_event, event}, _from, state) do
    {:ok, _event, new_state} = append_sequenced_event(state, event)
    new_state = notify_waiters(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:append_event_with_sequence, event}, _from, state) do
    {:ok, stored_event, new_state} = append_sequenced_event(state, event)
    new_state = notify_waiters(new_state)
    {:reply, {:ok, stored_event}, new_state}
  end

  def handle_call({:append_events, events}, _from, state) do
    with :ok <- validate_event_structs(events),
         {:ok, stored_events, new_state} <- append_sequenced_events(state, events) do
      new_state = notify_waiters(new_state)
      {:reply, {:ok, stored_events}, new_state}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:flush, %{session: %Session{} = session, run: %Run{} = run, events: events}},
        _from,
        state
      )
      when is_list(events) do
    with :ok <- validate_event_structs(events),
         {:ok, _stored_events, appended_state} <- append_sequenced_events(state, events) do
      :ets.insert(appended_state.sessions, {session.id, session})
      :ets.insert(appended_state.runs, {run.id, run})
      appended_state = notify_waiters(appended_state)
      {:reply, :ok, appended_state}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:flush, _invalid_payload}, _from, state) do
    {:reply, {:error, Error.new(:validation_error, "invalid execution_result payload")}, state}
  end

  def handle_call({:get_events, session_id, opts}, from, state) do
    events =
      queue_to_events(state.events)
      |> Enum.filter(&(&1.session_id == session_id))
      |> filter_events(opts)

    wait_timeout_ms = Keyword.get(opts, :wait_timeout_ms, 0)

    if events == [] and is_integer(wait_timeout_ms) and wait_timeout_ms > 0 do
      # Long-poll: defer reply until matching events arrive or timeout
      timer_ref = Process.send_after(self(), {:waiter_timeout, from}, wait_timeout_ms)
      waiter = {from, session_id, opts, timer_ref}
      {:noreply, %{state | waiters: state.waiters ++ [waiter]}}
    else
      {:reply, {:ok, events}, state}
    end
  end

  def handle_call({:get_latest_sequence, session_id}, _from, state) do
    latest = Map.get(state.session_sequences, session_id, 0)
    {:reply, {:ok, latest}, state}
  end

  @impl GenServer
  def handle_info({:waiter_timeout, from}, state) do
    # Find and remove the timed-out waiter, reply with empty list
    case Enum.split_with(state.waiters, fn {w_from, _sid, _opts, _ref} -> w_from == from end) do
      {[_expired], remaining} ->
        GenServer.reply(from, {:ok, []})
        {:noreply, %{state | waiters: remaining}}

      {[], _} ->
        # Already resolved (event arrived before timeout)
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cancel pending waiter timers and reply to waiters
    Enum.each(state.waiters, fn {from, _sid, _opts, timer_ref} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:ok, []})
    end)

    # Clean up ETS tables
    :ets.delete(state.sessions)
    :ets.delete(state.runs)
    :ets.delete(state.event_ids)
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp filter_sessions(sessions, opts) do
    sessions
    |> maybe_filter_by_status(opts)
    |> maybe_filter_by_agent_id(opts)
    |> maybe_limit(opts)
  end

  defp filter_runs(runs, opts) do
    runs
    |> maybe_filter_by_status(opts)
    |> maybe_limit(opts)
  end

  defp filter_events(events, opts) do
    events
    |> maybe_filter_by_run_id(opts)
    |> maybe_filter_by_type(opts)
    |> maybe_filter_since(opts)
    |> maybe_filter_after(opts)
    |> maybe_filter_before(opts)
    |> maybe_limit(opts)
  end

  defp maybe_filter_by_status(items, opts) do
    case Keyword.get(opts, :status) do
      nil -> items
      status -> Enum.filter(items, &(&1.status == status))
    end
  end

  defp maybe_filter_by_agent_id(items, opts) do
    case Keyword.get(opts, :agent_id) do
      nil -> items
      agent_id -> Enum.filter(items, &(&1.agent_id == agent_id))
    end
  end

  defp maybe_filter_by_run_id(events, opts) do
    case Keyword.get(opts, :run_id) do
      nil -> events
      run_id -> Enum.filter(events, &(&1.run_id == run_id))
    end
  end

  defp maybe_filter_by_type(events, opts) do
    case Keyword.get(opts, :type) do
      nil -> events
      type -> Enum.filter(events, &(&1.type == type))
    end
  end

  defp maybe_filter_since(events, opts) do
    case Keyword.get(opts, :since) do
      nil ->
        events

      since when is_struct(since, DateTime) ->
        Enum.filter(events, fn event ->
          DateTime.compare(event.timestamp, since) in [:gt, :eq]
        end)
    end
  end

  defp maybe_filter_after(events, opts) do
    case Keyword.get(opts, :after) do
      nil ->
        events

      after_cursor when is_integer(after_cursor) and after_cursor >= 0 ->
        Enum.filter(events, fn event ->
          is_integer(event.sequence_number) and event.sequence_number > after_cursor
        end)

      _ ->
        events
    end
  end

  defp maybe_filter_before(events, opts) do
    case Keyword.get(opts, :before) do
      nil ->
        events

      before_cursor when is_integer(before_cursor) and before_cursor >= 0 ->
        Enum.filter(events, fn event ->
          is_integer(event.sequence_number) and event.sequence_number < before_cursor
        end)

      _ ->
        events
    end
  end

  defp maybe_limit(items, opts) do
    case Keyword.get(opts, :limit) do
      nil -> items
      limit when is_integer(limit) and limit > 0 -> Enum.take(items, limit)
      _ -> items
    end
  end

  defp notify_waiters(state) do
    {resolved, remaining} =
      Enum.split_with(state.waiters, fn {_from, session_id, opts, _ref} ->
        events =
          queue_to_events(state.events)
          |> Enum.filter(&(&1.session_id == session_id))
          |> filter_events(opts)

        events != []
      end)

    Enum.each(resolved, fn {from, session_id, opts, timer_ref} ->
      Process.cancel_timer(timer_ref)

      events =
        queue_to_events(state.events)
        |> Enum.filter(&(&1.session_id == session_id))
        |> filter_events(opts)

      GenServer.reply(from, {:ok, events})
    end)

    %{state | waiters: remaining}
  end

  defp append_sequenced_event(state, %Event{} = event) do
    case :ets.lookup(state.event_ids, event.id) do
      [{_event_id, existing_event}] ->
        {:ok, existing_event, state}

      [] ->
        latest_sequence = Map.get(state.session_sequences, event.session_id, 0)
        next_sequence = latest_sequence + 1
        sequenced_event = %{event | sequence_number: next_sequence}

        :ets.insert(state.event_ids, {event.id, sequenced_event})

        new_state = %{
          state
          | events: :queue.in(sequenced_event, state.events),
            session_sequences: Map.put(state.session_sequences, event.session_id, next_sequence)
        }

        {:ok, sequenced_event, new_state}
    end
  end

  defp append_sequenced_events(state, events) do
    Enum.reduce_while(events, {:ok, [], state}, fn
      %Event{} = event, {:ok, acc, current_state} ->
        {:ok, stored_event, next_state} = append_sequenced_event(current_state, event)
        {:cont, {:ok, [stored_event | acc], next_state}}

      _other, _acc ->
        {:halt, {:error, Error.new(:validation_error, "events must be Event structs")}}
    end)
    |> case do
      {:ok, stored_events, new_state} -> {:ok, Enum.reverse(stored_events), new_state}
      {:error, _} = error -> error
    end
  end

  defp validate_event_structs(events) when is_list(events) do
    if Enum.all?(events, &match?(%Event{}, &1)) do
      :ok
    else
      {:error, Error.new(:validation_error, "events must be Event structs")}
    end
  end

  defp queue_to_events(events_queue), do: :queue.to_list(events_queue)
end
