defmodule AgentSessionManager.Runtime.SessionServer do
  @moduledoc """
  Per-session runtime server (GenServer) providing:

  - FIFO run queueing with strict sequential execution (MVP)
  - submit/await/cancel run semantics
  - event subscriptions backed by the durable event store
  - optional `ConcurrencyLimiter` integration

  The server delegates run lifecycle work to `SessionManager` APIs.
  """

  use GenServer

  alias AgentSessionManager.Concurrency.ConcurrencyLimiter
  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.Runtime.RunQueue
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Telemetry

  @type submit_opts :: keyword()
  @type subscribe_opts :: [
          {:from_sequence, non_neg_integer()}
          | {:run_id, String.t()}
          | {:type, Event.event_type()}
        ]

  @default_max_queued_runs 100
  @default_await_timeout 60_000

  # ============================================================================
  # Public API
  # ============================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    max_concurrent_runs = Keyword.get(opts, :max_concurrent_runs, 1)

    if max_concurrent_runs != 1 do
      {:error,
       Error.new(
         :validation_error,
         "MVP runtime supports strict sequential execution only (max_concurrent_runs must be 1)"
       )}
    else
      try do
        if name do
          GenServer.start_link(__MODULE__, opts, name: name)
        else
          GenServer.start_link(__MODULE__, opts)
        end
      catch
        :exit, %Error{} = error -> {:error, error}
        :exit, {:shutdown, %Error{} = error} -> {:error, error}
      end
    end
  end

  @spec submit_run(GenServer.server(), map(), submit_opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def submit_run(server, input, opts \\ []) when is_map(input) and is_list(opts) do
    GenServer.call(server, {:submit_run, input, opts})
  end

  @spec execute_run(GenServer.server(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def execute_run(server, input, opts \\ []) when is_map(input) and is_list(opts) do
    await_timeout = Keyword.get(opts, :timeout, @default_await_timeout)

    case submit_run(server, input, opts) do
      {:ok, run_id} -> await_run(server, run_id, await_timeout)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec await_run(GenServer.server(), String.t(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def await_run(server, run_id, timeout \\ @default_await_timeout) when is_binary(run_id) do
    GenServer.call(server, {:await_run, run_id}, timeout)
  end

  @spec cancel_run(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def cancel_run(server, run_id) when is_binary(run_id) do
    GenServer.call(server, {:cancel_run, run_id})
  end

  @spec subscribe(GenServer.server(), subscribe_opts()) ::
          {:ok, reference()} | {:error, Error.t()}
  def subscribe(server, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:subscribe, self(), opts})
  end

  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(server, ref) when is_reference(ref) do
    GenServer.call(server, {:unsubscribe, ref})
  end

  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    adapter = Keyword.fetch!(opts, :adapter)

    max_concurrent_runs = Keyword.get(opts, :max_concurrent_runs, 1)

    if max_concurrent_runs != 1 do
      {:stop,
       Error.new(
         :validation_error,
         "MVP runtime supports strict sequential execution only (max_concurrent_runs must be 1)"
       )}
    else
      limiter = Keyword.get(opts, :limiter)
      default_execute_opts = Keyword.get(opts, :default_execute_opts, [])
      max_queued_runs = Keyword.get(opts, :max_queued_runs, @default_max_queued_runs)

      with {:ok, session} <- ensure_session(store, adapter, opts),
           {:ok, cursor} <- SessionStore.get_latest_sequence(store, session.id) do
        runtime_telemetry([:session_server, :start], %{system_time: System.system_time()}, %{
          session_id: session.id
        })

        {:ok,
         %{
           store: store,
           adapter: adapter,
           limiter: limiter,
           default_execute_opts: default_execute_opts,
           session_id: session.id,
           max_concurrent_runs: 1,
           queue: RunQueue.new(max_queued_runs: max_queued_runs),
           max_queued_runs: max_queued_runs,
           active_run: nil,
           # run_id => keyword()
           run_execute_opts: %{},
           # run_id => {:ok, result} | {:error, error}
           run_results: %{},
           # run_id => [GenServer.from()]
           awaiters: %{},
           # ref => %{pid, from_sequence, run_id, type, monitor_ref}
           subscribers: %{},
           # global dispatch cursor for incremental fanout
           dispatch_cursor: cursor,
           dispatch_scheduled?: false,
           # {run_id => true} for limiter acquisitions
           limiter_acquired: %{}
         }}
      else
        {:error, %Error{} = error} ->
          {:stop, error}
      end
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      session_id: state.session_id,
      active_run_id: active_run_id(state.active_run),
      queued_runs: RunQueue.to_list(state.queue),
      queued_count: RunQueue.size(state.queue),
      max_concurrent_runs: state.max_concurrent_runs,
      max_queued_runs: state.max_queued_runs,
      subscribers: map_size(state.subscribers)
    }

    {:reply, status, state}
  end

  def handle_call({:submit_run, input, submit_opts}, _from, state) do
    if RunQueue.size(state.queue) >= state.max_queued_runs do
      {:reply,
       {:error,
        Error.new(:max_runs_exceeded, "Maximum queued runs exceeded (#{state.max_queued_runs})")},
       state}
    else
      execute_opts = normalize_execute_opts(submit_opts)

      case SessionManager.start_run(state.store, state.adapter, state.session_id, input, []) do
        {:ok, %Run{} = run} ->
          state =
            state
            |> put_run_execute_opts(run.id, execute_opts)
            |> enqueue_run(run.id)
            |> maybe_start_next_run()

          {:reply, {:ok, run.id}, state}

        {:error, %Error{} = error} ->
          {:reply, {:error, error}, state}
      end
    end
  end

  def handle_call({:await_run, run_id}, from, state) do
    case Map.fetch(state.run_results, run_id) do
      {:ok, result} ->
        {:reply, unwrap_result(result), state}

      :error ->
        awaiters = Map.update(state.awaiters, run_id, [from], fn list -> [from | list] end)
        {:noreply, %{state | awaiters: awaiters}}
    end
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    if active_run_id(state.active_run) == run_id do
      {:reply, :ok, cancel_active_run(state, run_id)}
    else
      cancel_non_active_run(state, run_id)
    end
  end

  def handle_call({:subscribe, pid, opts}, _from, state) when is_pid(pid) do
    from_sequence = Keyword.get(opts, :from_sequence, 0)
    run_id = Keyword.get(opts, :run_id)
    type = Keyword.get(opts, :type)

    if not is_integer(from_sequence) or from_sequence < 0 do
      {:reply,
       {:error, Error.new(:validation_error, "from_sequence must be a non-negative integer")},
       state}
    else
      ref = make_ref()
      mon_ref = Process.monitor(pid)

      sub = %{
        pid: pid,
        from_sequence: from_sequence,
        run_id: run_id,
        type: type,
        monitor_ref: mon_ref
      }

      state = %{state | subscribers: Map.put(state.subscribers, ref, sub)}

      _ = send_backlog_events(state, sub)

      runtime_telemetry(
        [:session_server, :subscribe],
        %{count: map_size(state.subscribers)},
        %{session_id: state.session_id}
      )

      {:reply, {:ok, ref}, state}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    {sub, subscribers} = Map.pop(state.subscribers, ref)

    if sub do
      Process.demonitor(sub.monitor_ref, [:flush])
    end

    runtime_telemetry(
      [:session_server, :unsubscribe],
      %{count: map_size(subscribers)},
      %{session_id: state.session_id}
    )

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_info({:event_tick, _run_id}, state) do
    {:noreply, schedule_dispatch(state)}
  end

  def handle_info(:dispatch_new_events, state) do
    state = %{state | dispatch_scheduled?: false}
    {:noreply, dispatch_new_events(state)}
  end

  def handle_info({:run_finished, run_id, result}, state) do
    state = maybe_release_limiter(state, run_id)
    state = record_run_result(state, run_id, result)
    state = clear_active_run(state, run_id)
    state = dispatch_new_events(state)
    {:noreply, maybe_start_next_run(state)}
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, reason}, state) do
    state =
      case find_subscriber_by_monitor(state, mon_ref) do
        {:ok, ref} ->
          %{state | subscribers: Map.delete(state.subscribers, ref)}

        :error ->
          handle_task_down(state, mon_ref, reason)
      end

    {:noreply, state}
  end

  # ============================================================================
  # Session bootstrap
  # ============================================================================

  defp ensure_session(store, adapter, opts) do
    cond do
      session_id = Keyword.get(opts, :session_id) ->
        with {:ok, %Session{} = session} <- SessionStore.get_session(store, session_id),
             {:ok, _} <- SessionManager.activate_session(store, session.id) do
          {:ok, session}
        end

      session_opts = Keyword.get(opts, :session_opts) ->
        with {:ok, %Session{} = session} <-
               SessionManager.start_session(store, adapter, session_opts),
             {:ok, _} <- SessionManager.activate_session(store, session.id) do
          {:ok, session}
        end

      true ->
        {:error,
         Error.new(
           :validation_error,
           "SessionServer requires :session_id (existing) or :session_opts (to create)"
         )}
    end
  end

  # ============================================================================
  # Queue + execution
  # ============================================================================

  defp enqueue_run(state, run_id) do
    case RunQueue.enqueue(state.queue, run_id) do
      {:ok, queue} ->
        runtime_telemetry(
          [:session_server, :queue, :enqueue],
          %{queue_length: RunQueue.size(queue)},
          %{session_id: state.session_id, run_id: run_id}
        )

        %{state | queue: queue}

      {:error, :queue_full} ->
        state
    end
  end

  defp maybe_start_next_run(state) do
    if state.active_run != nil do
      state
    else
      dequeue_and_start(state)
    end
  end

  defp start_run_execution(state, run_id) do
    case maybe_acquire_limiter(state, run_id) do
      {:ok, state} ->
        execute_opts = build_execute_opts(state, run_id)
        task_ref = start_execution_task(state, run_id, execute_opts)

        runtime_telemetry(
          [:session_server, :run, :start],
          %{system_time: System.system_time()},
          %{session_id: state.session_id, run_id: run_id}
        )

        %{state | active_run: %{run_id: run_id, task_ref: task_ref}}

      {:error, %Error{} = error} ->
        state = record_run_result(state, run_id, {:error, error})
        maybe_start_next_run(state)
    end
  end

  defp active_run_id(nil), do: nil
  defp active_run_id(%{run_id: run_id}), do: run_id

  defp clear_active_run(state, run_id) do
    if active_run_id(state.active_run) == run_id do
      runtime_telemetry(
        [:session_server, :run, :stop],
        %{system_time: System.system_time()},
        %{session_id: state.session_id, run_id: run_id}
      )

      %{state | active_run: nil, run_execute_opts: Map.delete(state.run_execute_opts, run_id)}
    else
      state
    end
  end

  defp put_run_execute_opts(state, run_id, execute_opts) do
    %{state | run_execute_opts: Map.put(state.run_execute_opts, run_id, execute_opts)}
  end

  defp record_run_result(state, run_id, result) do
    state = %{state | run_results: Map.put(state.run_results, run_id, result)}
    state = notify_awaiters(state, run_id, result)
    state
  end

  defp notify_awaiters(state, run_id, result) do
    {awaiters, awaiters_map} = Map.pop(state.awaiters, run_id, [])
    state = %{state | awaiters: awaiters_map}

    Enum.each(awaiters, fn from ->
      GenServer.reply(from, unwrap_result(result))
    end)

    state
  end

  defp unwrap_result({:ok, result}), do: {:ok, result}
  defp unwrap_result({:error, %Error{} = error}), do: {:error, error}
  defp unwrap_result({:error, other}), do: {:error, Error.new(:internal_error, inspect(other))}

  defp normalize_execute_opts(opts) do
    Keyword.drop(opts, [:timeout])
  end

  defp merge_execute_opts(defaults, overrides) do
    Keyword.merge(defaults, overrides, fn
      :adapter_opts, left, right when is_list(left) and is_list(right) ->
        Keyword.merge(left, right)

      _key, _left, right ->
        right
    end)
  end

  # ============================================================================
  # Cancel queued run (no provider call)
  # ============================================================================

  defp cancel_queued_run(state, run_id) do
    cancelled_error = Error.new(:cancelled, "Run cancelled")

    with {:ok, %Run{} = run} <- SessionStore.get_run(state.store, run_id),
         {:ok, %Run{} = cancelled} <- Run.update_status(run, :cancelled),
         :ok <- SessionStore.save_run(state.store, cancelled),
         {:ok, _} <- append_cancelled_event(state, run_id) do
      state = record_run_result(state, run_id, {:error, cancelled_error})
      state = dispatch_new_events(state)

      runtime_telemetry([:session_server, :cancel, :queued], %{}, %{
        session_id: state.session_id,
        run_id: run_id
      })

      {:ok, state}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp append_cancelled_event(state, run_id) do
    with {:ok, event} <-
           Event.new(%{
             type: :run_cancelled,
             session_id: state.session_id,
             run_id: run_id,
             data: %{}
           }) do
      SessionStore.append_event_with_sequence(state.store, event)
    end
  end

  # ============================================================================
  # Subscription fanout (store-backed)
  # ============================================================================

  defp send_backlog_events(state, sub) do
    after_cursor =
      case sub.from_sequence do
        0 -> 0
        n when is_integer(n) and n > 0 -> n - 1
      end

    query_opts =
      []
      |> Keyword.put(:after, after_cursor)
      |> maybe_put(:run_id, sub.run_id)
      |> maybe_put(:type, sub.type)
      |> Keyword.put(:limit, 1_000)

    with {:ok, events} <- SessionStore.get_events(state.store, state.session_id, query_opts) do
      events
      |> Enum.filter(&match_sub?(sub, &1))
      |> Enum.each(fn event -> send(sub.pid, {:session_event, state.session_id, event}) end)
    end
  end

  defp dispatch_new_events(state) do
    if map_size(state.subscribers) == 0 do
      state
    else
      do_dispatch_new_events(state)
    end
  end

  defp do_dispatch_new_events(state) do
    query_opts = [after: state.dispatch_cursor, limit: 500]

    case SessionStore.get_events(state.store, state.session_id, query_opts) do
      {:ok, []} ->
        state

      {:ok, events} ->
        Enum.each(events, fn event -> dispatch_event(state, event) end)

        new_cursor = List.last(events).sequence_number || state.dispatch_cursor
        %{state | dispatch_cursor: new_cursor}
    end
  end

  defp dispatch_event(state, event) do
    Enum.each(state.subscribers, fn {_ref, sub} ->
      dispatch_to_subscriber(state.session_id, sub, event)
    end)
  end

  defp dispatch_to_subscriber(session_id, sub, event) do
    if match_sub?(sub, event) do
      send(sub.pid, {:session_event, session_id, event})
    end
  end

  defp dequeue_and_start(state) do
    case RunQueue.dequeue(state.queue) do
      {:ok, run_id, queue} ->
        state = %{state | queue: queue}

        runtime_telemetry(
          [:session_server, :queue, :dequeue],
          %{queue_length: RunQueue.size(queue)},
          %{session_id: state.session_id, run_id: run_id}
        )

        start_run_execution(state, run_id)

      {:empty, _queue} ->
        state
    end
  end

  defp build_execute_opts(state, run_id) do
    per_run = Map.get(state.run_execute_opts, run_id, [])
    execute_opts = merge_execute_opts(state.default_execute_opts || [], per_run)
    wrap_event_callback(execute_opts, run_id)
  end

  defp wrap_event_callback(execute_opts, run_id) do
    user_callback = Keyword.get(execute_opts, :event_callback)
    server_pid = self()

    Keyword.put(execute_opts, :event_callback, fn event_data ->
      send(server_pid, {:event_tick, run_id})

      if is_function(user_callback, 1) do
        user_callback.(event_data)
      end
    end)
  end

  defp start_execution_task(state, run_id, execute_opts) do
    server_pid = self()

    {:ok, task_pid} =
      Task.start(fn ->
        result = SessionManager.execute_run(state.store, state.adapter, run_id, execute_opts)
        send(server_pid, {:run_finished, run_id, result})
      end)

    task_ref = Process.monitor(task_pid)
    task_ref
  end

  defp cancel_active_run(state, run_id) do
    _ = Task.start(fn -> _ = SessionManager.cancel_run(state.store, state.adapter, run_id) end)

    runtime_telemetry([:session_server, :cancel, :active], %{}, %{
      session_id: state.session_id,
      run_id: run_id
    })

    state
  end

  defp cancel_non_active_run(state, run_id) do
    case RunQueue.remove(state.queue, run_id) do
      {:ok, new_queue} ->
        state = %{state | queue: new_queue}
        state = maybe_cancel_queued_run(state, run_id)
        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, cancel_unknown_or_finished(state, run_id), state}
    end
  end

  defp maybe_cancel_queued_run(state, run_id) do
    case cancel_queued_run(state, run_id) do
      {:ok, new_state} -> new_state
      {:error, _} -> state
    end
  end

  defp cancel_unknown_or_finished(state, run_id) do
    if Map.has_key?(state.run_results, run_id) do
      :ok
    else
      {:error, Error.new(:run_not_found, "Run not found in queue: #{run_id}")}
    end
  end

  defp match_sub?(sub, %Event{} = event) do
    (is_nil(sub.type) or event.type == sub.type) and
      (is_nil(sub.run_id) or event.run_id == sub.run_id) and
      (is_nil(event.sequence_number) or event.sequence_number >= sub.from_sequence)
  end

  defp schedule_dispatch(state) do
    if state.dispatch_scheduled? do
      state
    else
      Process.send_after(self(), :dispatch_new_events, 0)
      %{state | dispatch_scheduled?: true}
    end
  end

  defp find_subscriber_by_monitor(state, mon_ref) do
    state.subscribers
    |> Enum.find(fn {_ref, sub} -> sub.monitor_ref == mon_ref end)
    |> case do
      {ref, _sub} -> {:ok, ref}
      nil -> :error
    end
  end

  # ============================================================================
  # Task failure handling
  # ============================================================================

  defp handle_task_down(state, mon_ref, reason) do
    if state.active_run && state.active_run.task_ref == mon_ref do
      run_id = state.active_run.run_id
      state = maybe_release_limiter(state, run_id)

      error =
        Error.new(
          :internal_error,
          "Run task crashed: #{inspect(reason)}"
        )

      state = record_run_result(state, run_id, {:error, error})
      state = clear_active_run(state, run_id)
      maybe_start_next_run(state)
    else
      state
    end
  end

  # ============================================================================
  # Limiter integration
  # ============================================================================

  defp maybe_acquire_limiter(state, run_id) do
    if state.limiter do
      case ConcurrencyLimiter.acquire_run_slot(state.limiter, state.session_id, run_id) do
        :ok ->
          {:ok, %{state | limiter_acquired: Map.put(state.limiter_acquired, run_id, true)}}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    else
      {:ok, state}
    end
  end

  defp maybe_release_limiter(state, run_id) do
    if state.limiter && Map.get(state.limiter_acquired, run_id, false) do
      _ = ConcurrencyLimiter.release_run_slot(state.limiter, run_id)
      %{state | limiter_acquired: Map.delete(state.limiter_acquired, run_id)}
    else
      state
    end
  end

  # ============================================================================
  # Telemetry helpers
  # ============================================================================

  defp runtime_telemetry(suffix, measurements, metadata) do
    if Telemetry.enabled?() do
      :telemetry.execute([:agent_session_manager, :runtime] ++ suffix, measurements, metadata)
    end

    :ok
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
