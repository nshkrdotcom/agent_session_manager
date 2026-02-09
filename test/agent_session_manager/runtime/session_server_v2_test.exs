defmodule AgentSessionManager.Runtime.SessionServerV2Test do
  @moduledoc """
  Phase 2 Feature 6 tests for multi-slot concurrency, durable subscriptions,
  operational APIs, and control operations integration.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Concurrency.{ConcurrencyLimiter, ControlOperations}
  alias AgentSessionManager.Core.{Error, Event}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.Runtime.SessionServer

  # ============================================================================
  # Shared test adapter that supports blocking and controlled completion
  # ============================================================================

  defmodule BlockingTestAdapter do
    @moduledoc false

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer

    alias AgentSessionManager.Core.{Capability, Error}

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def allow(adapter, run_id) do
      GenServer.cast(adapter, {:allow, run_id})
    end

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         allowed: MapSet.new(),
         pending: %{},
         capabilities: [
           %Capability{name: "chat", type: :tool, enabled: true},
           %Capability{name: "streaming", type: :sampling, enabled: true}
         ]
       }}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "blocking_test"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts}, :infinity)
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(_adapter, run_id), do: {:ok, run_id}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    @impl GenServer
    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, state.capabilities}, state}
    end

    def handle_call(:name, _from, state) do
      {:reply, "blocking_test", state}
    end

    def handle_call({:cancel, run_id}, _from, state) do
      {:reply, {:ok, run_id}, state}
    end

    def handle_call({:execute, run, _session, opts}, from, state) do
      send(state.test_pid, {:adapter_execute_called, run.id})

      if MapSet.member?(state.allowed, run.id) do
        {:reply, execute_now(run, opts), state}
      else
        pending = Map.put(state.pending, run.id, {from, run, opts})
        {:noreply, %{state | pending: pending}}
      end
    end

    @impl GenServer
    def handle_cast({:allow, run_id}, state) do
      state = %{state | allowed: MapSet.put(state.allowed, run_id)}

      case Map.pop(state.pending, run_id) do
        {nil, pending} ->
          {:noreply, %{state | pending: pending}}

        {{from, run, opts}, pending} ->
          GenServer.reply(from, execute_now(run, opts))
          {:noreply, %{state | pending: pending}}
      end
    end

    defp execute_now(run, opts) do
      event_callback = Keyword.get(opts, :event_callback)
      timestamp = DateTime.utc_now()

      if is_function(event_callback, 1) do
        event_callback.(%{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: timestamp
        })

        event_callback.(%{
          type: :message_received,
          session_id: run.session_id,
          run_id: run.id,
          data: %{content: "ok from #{run.id}"},
          timestamp: timestamp
        })

        event_callback.(%{
          type: :run_completed,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: timestamp
        })
      end

      {:ok, %{output: %{content: "ok from #{run.id}"}, token_usage: %{}, events: []}}
    rescue
      error ->
        {:error, Error.new(:internal_error, "Adapter failed: #{Exception.message(error)}")}
    end
  end

  setup ctx do
    {:ok, store} = InMemorySessionStore.start_link([])
    {:ok, adapter} = BlockingTestAdapter.start_link(test_pid: self())

    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> safe_stop(adapter) end)

    ctx
    |> Map.put(:store, store)
    |> Map.put(:adapter, adapter)
  end

  # ============================================================================
  # Multi-slot concurrency tests
  # ============================================================================

  describe "multi-slot concurrency (max_concurrent_runs > 1)" do
    test "accepts max_concurrent_runs > 1 in Phase 2", %{store: store, adapter: adapter} do
      assert {:ok, server} =
               SessionServer.start_link(
                 store: store,
                 adapter: adapter,
                 session_opts: %{agent_id: "agent"},
                 max_concurrent_runs: 3
               )

      cleanup_on_exit(fn -> safe_stop(server) end)

      status = SessionServer.status(server)
      assert status.max_concurrent_runs == 3
    end

    test "runs up to max_concurrent_runs in parallel", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])
      assert {:ok, run3} = SessionServer.submit_run(server, %{prompt: "three"}, [])

      # Both run1 and run2 should start (2 slots available)
      assert_receive {:adapter_execute_called, ^run1}, 1_000
      assert_receive {:adapter_execute_called, ^run2}, 1_000
      # run3 must NOT start yet (slots full)
      refute_receive {:adapter_execute_called, ^run3}, 300

      status = SessionServer.status(server)
      assert status.in_flight_count == 2
      assert status.queued_count == 1
    end

    test "never exceeds configured slots", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      # Submit 5 runs
      run_ids =
        for i <- 1..5 do
          {:ok, id} = SessionServer.submit_run(server, %{prompt: "run #{i}"}, [])
          id
        end

      # Only 2 should start
      assert_receive {:adapter_execute_called, _}, 1_000
      assert_receive {:adapter_execute_called, _}, 1_000
      refute_receive {:adapter_execute_called, _}, 300

      status = SessionServer.status(server)
      assert status.in_flight_count == 2
      assert status.queued_count == 3

      # Complete first two, next two should start
      [run1, run2 | _rest] = run_ids
      BlockingTestAdapter.allow(adapter, run1)
      BlockingTestAdapter.allow(adapter, run2)

      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)

      # Next 2 should start
      assert_receive {:adapter_execute_called, _}, 1_000
      assert_receive {:adapter_execute_called, _}, 1_000
    end

    test "drains queue as slots become available", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])
      assert {:ok, run3} = SessionServer.submit_run(server, %{prompt: "three"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000
      assert_receive {:adapter_execute_called, ^run2}, 1_000

      # Complete run1 -> run3 should start
      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      assert_receive {:adapter_execute_called, ^run3}, 1_000

      # Complete remaining
      BlockingTestAdapter.allow(adapter, run2)
      BlockingTestAdapter.allow(adapter, run3)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)
      assert {:ok, _} = SessionServer.await_run(server, run3, 2_000)
    end

    test "FIFO fairness: queued runs start in submission order", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])
      assert {:ok, run3} = SessionServer.submit_run(server, %{prompt: "three"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000
      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      # run2 should start next (not run3)
      assert_receive {:adapter_execute_called, ^run2}, 1_000
      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)

      assert_receive {:adapter_execute_called, ^run3}, 1_000
      BlockingTestAdapter.allow(adapter, run3)
      assert {:ok, _} = SessionServer.await_run(server, run3, 2_000)
    end

    test "cancelling a queued run does not affect in-flight runs", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])
      assert {:ok, run3} = SessionServer.submit_run(server, %{prompt: "three"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000
      assert_receive {:adapter_execute_called, ^run2}, 1_000

      # Cancel queued run3
      assert :ok = SessionServer.cancel_run(server, run3)

      # In-flight runs should still work fine
      BlockingTestAdapter.allow(adapter, run1)
      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)

      # run3 was cancelled
      assert {:error, %Error{code: :cancelled}} = SessionServer.await_run(server, run3, 2_000)
    end

    test "cancelling an in-flight run frees a slot for the queue", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000

      # Cancel the active run
      assert :ok = SessionServer.cancel_run(server, run1)

      # run2 should start as the slot freed up
      # (Note: cancellation of active run is async via adapter)
      # The server receives :run_finished or task :DOWN, which triggers queue drain
      # Allow run1 to complete (the cancel was already sent, but it should still complete)
      BlockingTestAdapter.allow(adapter, run1)

      assert_receive {:adapter_execute_called, ^run2}, 2_000
      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)
    end

    test "limiter integration with multi-slot", %{store: store, adapter: adapter} do
      {:ok, limiter} =
        ConcurrencyLimiter.start_link(max_parallel_sessions: 10, max_parallel_runs: 2)

      cleanup_on_exit(fn -> safe_stop(limiter) end)

      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          limiter: limiter
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000
      assert_receive {:adapter_execute_called, ^run2}, 1_000

      assert ConcurrencyLimiter.get_status(limiter).active_runs == 2

      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      # Wait for limiter release
      Process.sleep(100)
      assert ConcurrencyLimiter.get_status(limiter).active_runs == 1

      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)

      Process.sleep(100)
      assert ConcurrencyLimiter.get_status(limiter).active_runs == 0
    end

    test "task crash releases slot and starts next queued run", %{store: store} do
      # Use a special adapter that crashes for specific runs
      {:ok, crashing_adapter} = __MODULE__.CrashingTestAdapter.start_link(test_pid: self())
      cleanup_on_exit(fn -> safe_stop(crashing_adapter) end)

      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: crashing_adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "crash"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "ok"}, [])

      # run1 will crash on execute
      assert_receive {:adapter_execute_called, ^run1}, 1_000
      __MODULE__.CrashingTestAdapter.allow(crashing_adapter, run1, :crash)

      # run1 should fail and run2 should start
      assert {:error, %Error{}} = SessionServer.await_run(server, run1, 2_000)

      assert_receive {:adapter_execute_called, ^run2}, 2_000
      __MODULE__.CrashingTestAdapter.allow(crashing_adapter, run2, :ok)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)
    end

    test "status includes in_flight_count", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 3,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      status = SessionServer.status(server)
      assert status.in_flight_count == 0
      assert status.queued_count == 0
      assert status.max_concurrent_runs == 3

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run1}, 1_000

      status = SessionServer.status(server)
      assert status.in_flight_count == 1
    end
  end

  # ============================================================================
  # Durable subscription tests
  # ============================================================================

  describe "durable subscriptions (backfill + live)" do
    test "backfills from store on subscribe with from_sequence", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      # Execute a run first (creates events in store)
      assert {:ok, run_id} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run_id}, 1_000
      BlockingTestAdapter.allow(adapter, run_id)
      assert {:ok, _} = SessionServer.await_run(server, run_id, 2_000)

      # Now subscribe from sequence 0 - should get backfilled events
      assert {:ok, sub_ref} = SessionServer.subscribe(server, from_sequence: 0)
      assert is_reference(sub_ref)

      # Should receive backfilled events from store
      events = collect_events(500)
      assert events != []

      # All events should have valid sequence numbers
      Enum.each(events, fn {_sid, event} ->
        assert is_integer(event.sequence_number)
        assert event.sequence_number > 0
      end)

      :ok = SessionServer.unsubscribe(server, sub_ref)
    end

    test "delivers live events after backfill without gaps", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      # Execute first run
      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run1}, 1_000
      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      # Get the latest sequence after first run
      {:ok, latest_seq} =
        SessionStore.get_latest_sequence(store, SessionServer.status(server).session_id)

      # Subscribe from latest - should get no backfill
      assert {:ok, sub_ref} = SessionServer.subscribe(server, from_sequence: latest_seq + 1)

      # No backfill events expected
      old_events = collect_events(200)
      assert old_events == []

      # Now submit and execute another run - should get live events
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])
      assert_receive {:adapter_execute_called, ^run2}, 1_000
      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)

      live_events = collect_events(1_000)
      assert live_events != []

      # All live events should be after the cursor
      Enum.each(live_events, fn {_sid, event} ->
        assert event.sequence_number > latest_seq
      end)

      :ok = SessionServer.unsubscribe(server, sub_ref)
    end

    test "subscriber can resume from a stored cursor", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      # Execute run
      assert {:ok, run_id} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run_id}, 1_000
      BlockingTestAdapter.allow(adapter, run_id)
      assert {:ok, _} = SessionServer.await_run(server, run_id, 2_000)

      # Subscribe from 0, collect all events
      assert {:ok, ref1} = SessionServer.subscribe(server, from_sequence: 0)
      events1 = collect_events(500)
      :ok = SessionServer.unsubscribe(server, ref1)

      # Get max sequence from first batch
      max_seq =
        events1
        |> Enum.map(fn {_sid, event} -> event.sequence_number end)
        |> Enum.max()

      # Subscribe again from max_seq + 1 - should get no events
      assert {:ok, ref2} = SessionServer.subscribe(server, from_sequence: max_seq + 1)
      events2 = collect_events(200)
      assert events2 == []

      :ok = SessionServer.unsubscribe(server, ref2)
    end
  end

  # ============================================================================
  # Operational API tests
  # ============================================================================

  describe "operational APIs" do
    test "status returns comprehensive information", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          max_queued_runs: 50
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      status = SessionServer.status(server)

      assert is_binary(status.session_id)
      assert status.in_flight_count == 0
      assert status.queued_count == 0
      assert status.max_concurrent_runs == 2
      assert status.max_queued_runs == 50
      assert status.subscribers == 0
    end

    test "drain/2 waits for queue and in-flight to reach zero", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000
      assert_receive {:adapter_execute_called, ^run2}, 1_000

      # Start drain in a task since it blocks
      drain_task =
        Task.async(fn ->
          SessionServer.drain(server, 10_000)
        end)

      # Allow runs to complete
      Process.sleep(100)
      BlockingTestAdapter.allow(adapter, run1)
      BlockingTestAdapter.allow(adapter, run2)

      assert :ok = Task.await(drain_task, 15_000)

      status = SessionServer.status(server)
      assert status.in_flight_count == 0
      assert status.queued_count == 0
    end

    test "drain/2 returns :timeout when runs don't complete in time", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, _run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, _}, 1_000

      # Don't allow the run to complete - drain should timeout
      assert {:error, :timeout} = SessionServer.drain(server, 200)
    end

    test "status shows in_flight_runs list", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 2
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run1}, 1_000

      status = SessionServer.status(server)
      assert run1 in status.in_flight_runs
    end
  end

  # ============================================================================
  # Control operations integration tests
  # ============================================================================

  describe "control operations integration" do
    test "interrupt_run delegates to control operations when configured", %{
      store: store,
      adapter: adapter
    } do
      {:ok, control_ops} = ControlOperations.start_link(adapter: adapter)
      cleanup_on_exit(fn -> safe_stop(control_ops) end)

      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          control_ops: control_ops
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run1}, 1_000

      # Interrupt via SessionServer
      assert {:ok, ^run1} = SessionServer.interrupt_run(server, run1)

      # Control ops should have recorded the operation
      op_status = ControlOperations.get_operation_status(control_ops, run1)
      assert op_status.state == :interrupted
    end

    test "works without control_ops configured", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run_id} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run_id}, 1_000

      # Without control_ops, interrupt_run should still work via cancel delegation
      assert :ok = SessionServer.cancel_run(server, run_id)
    end
  end

  # ============================================================================
  # Backward compatibility tests (max_concurrent_runs: 1)
  # ============================================================================

  describe "backward compatibility (sequential mode)" do
    test "max_concurrent_runs: 1 preserves strict sequential semantics", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])

      # Only run1 should execute, not run2
      assert_receive {:adapter_execute_called, ^run1}, 1_000
      refute_receive {:adapter_execute_called, ^run2}, 300

      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      # Now run2 should start
      assert_receive {:adapter_execute_called, ^run2}, 1_000
      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp collect_events(timeout_ms) do
    collect_events_acc([], timeout_ms)
  end

  defp collect_events_acc(acc, timeout_ms) do
    receive do
      {:session_event, session_id, %Event{} = event} ->
        collect_events_acc([{session_id, event} | acc], timeout_ms)
    after
      timeout_ms ->
        Enum.reverse(acc)
    end
  end

  # ============================================================================
  # Test adapter that can crash on command
  # ============================================================================

  defmodule CrashingTestAdapter do
    @moduledoc false

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer

    alias AgentSessionManager.Core.{Capability, Error}

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def allow(adapter, run_id, mode \\ :ok) do
      GenServer.cast(adapter, {:allow, run_id, mode})
    end

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         pending: %{},
         capabilities: [
           %Capability{name: "chat", type: :tool, enabled: true}
         ]
       }}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "crashing_test"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts}, :infinity)
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(_adapter, run_id), do: {:ok, run_id}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    @impl GenServer
    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, state.capabilities}, state}
    end

    def handle_call(:name, _from, state) do
      {:reply, "crashing_test", state}
    end

    def handle_call({:execute, run, _session, opts}, from, state) do
      send(state.test_pid, {:adapter_execute_called, run.id})
      pending = Map.put(state.pending, run.id, {from, run, opts})
      {:noreply, %{state | pending: pending}}
    end

    @impl GenServer
    def handle_cast({:allow, run_id, mode}, state) do
      case Map.pop(state.pending, run_id) do
        {nil, pending} ->
          {:noreply, %{state | pending: pending}}

        {{from, run, opts}, pending} ->
          reply_to_pending(from, run, opts, mode)
          {:noreply, %{state | pending: pending}}
      end
    end

    defp reply_to_pending(from, run, opts, :ok) do
      emit_events(run, opts)

      GenServer.reply(
        from,
        {:ok, %{output: %{content: "ok"}, token_usage: %{}, events: []}}
      )
    end

    defp reply_to_pending(from, _run, _opts, :crash) do
      GenServer.reply(
        from,
        {:error, Error.new(:provider_error, "Provider crashed on purpose")}
      )
    end

    defp emit_events(run, opts) do
      event_callback = Keyword.get(opts, :event_callback)
      ts = DateTime.utc_now()

      if is_function(event_callback, 1) do
        event_callback.(%{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: ts
        })

        event_callback.(%{
          type: :run_completed,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: ts
        })
      end
    end
  end
end
