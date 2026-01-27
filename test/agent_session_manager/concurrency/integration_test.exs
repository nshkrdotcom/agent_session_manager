defmodule AgentSessionManager.Concurrency.IntegrationTest do
  @moduledoc """
  Integration tests for concurrency control components.

  These tests verify that ConcurrencyLimiter and ControlOperations
  work correctly with the SessionManager.

  Uses Supertester for robust async testing and process isolation.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Concurrency.{ConcurrencyLimiter, ControlOperations}
  alias AgentSessionManager.Core.{Capability, Error, Run}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  # ============================================================================
  # Mock Adapter for Integration Tests
  # ============================================================================

  defmodule MockIntegrationAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer
    use Supertester.TestableGenServer

    alias AgentSessionManager.Core.{Capability, Error}

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(_opts) do
      {:ok,
       %{
         capabilities: default_capabilities(),
         cancelled_runs: MapSet.new(),
         interrupted_runs: MapSet.new()
       }}
    end

    defp default_capabilities do
      [
        %Capability{name: "chat", type: :tool, enabled: true},
        %Capability{name: "sampling", type: :sampling, enabled: true},
        %Capability{name: "interrupt", type: :sampling, enabled: true}
      ]
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "mock_integration"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, _session, opts) do
      # Simulate slow execution to allow for cancellation testing
      event_callback = Keyword.get(opts, :event_callback)

      if event_callback do
        event_callback.(%{type: :run_started, run_id: run.id})
      end

      # Check if cancelled
      cancelled = GenServer.call(adapter, {:is_cancelled, run.id})

      if cancelled do
        {:error, Error.new(:cancelled, "Run was cancelled")}
      else
        result = %{
          output: %{content: "Test response"},
          token_usage: %{input_tokens: 5, output_tokens: 10},
          events: []
        }

        if event_callback do
          event_callback.(%{type: :run_completed, run_id: run.id})
        end

        {:ok, result}
      end
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id) do
      GenServer.call(adapter, {:cancel, run_id})
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    def interrupt(adapter, run_id) do
      GenServer.call(adapter, {:interrupt, run_id})
    end

    @impl GenServer
    def handle_call(:name, _from, state) do
      {:reply, "mock_integration", state}
    end

    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, state.capabilities}, state}
    end

    def handle_call({:cancel, run_id}, _from, state) do
      new_state = %{state | cancelled_runs: MapSet.put(state.cancelled_runs, run_id)}
      {:reply, {:ok, run_id}, new_state}
    end

    def handle_call({:interrupt, run_id}, _from, state) do
      new_state = %{state | interrupted_runs: MapSet.put(state.interrupted_runs, run_id)}
      {:reply, {:ok, run_id}, new_state}
    end

    def handle_call({:is_cancelled, run_id}, _from, state) do
      {:reply, MapSet.member?(state.cancelled_runs, run_id), state}
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup ctx do
    {:ok, store} = InMemorySessionStore.start_link()
    {:ok, adapter} = MockIntegrationAdapter.start_link()

    {:ok, limiter} =
      ConcurrencyLimiter.start_link(
        max_parallel_sessions: 2,
        max_parallel_runs: 3
      )

    {:ok, ops} = ControlOperations.start_link(adapter: adapter)

    on_exit(fn ->
      for pid <- [store, adapter, limiter, ops] do
        safe_stop(pid)
      end
    end)

    ctx
    |> Map.put(:store, store)
    |> Map.put(:adapter, adapter)
    |> Map.put(:limiter, limiter)
    |> Map.put(:ops, ops)
  end

  # ============================================================================
  # Session Limit Integration Tests
  # ============================================================================

  describe "session management with concurrency limits" do
    test "creates sessions up to limit", %{store: store, adapter: adapter, limiter: limiter} do
      # Create first session
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      {:ok, session1} = SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})
      assert session1.status == :pending

      # Create second session (at limit)
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      {:ok, session2} = SessionManager.start_session(store, adapter, %{agent_id: "agent-2"})
      assert session2.status == :pending

      # Third session should fail limiter check
      result = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")
      assert {:error, %Error{code: :max_sessions_exceeded}} = result
    end

    test "releasing a session allows new sessions", %{
      store: store,
      adapter: adapter,
      limiter: limiter
    } do
      # Fill up to limit
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      {:ok, _} = SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      {:ok, _} = SessionManager.start_session(store, adapter, %{agent_id: "agent-2"})

      # Can't create more
      assert {:error, _} = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")

      # Release one
      :ok = ConcurrencyLimiter.release_session_slot(limiter, "session-1")

      # Now can create
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")
      {:ok, session3} = SessionManager.start_session(store, adapter, %{agent_id: "agent-3"})
      assert session3.status == :pending
    end
  end

  # ============================================================================
  # Run Limit Integration Tests
  # ============================================================================

  describe "run management with concurrency limits" do
    test "creates runs up to limit", %{store: store, adapter: adapter, limiter: limiter} do
      # Setup sessions
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Create runs up to limit
      for i <- 1..3 do
        :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
        {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test #{i}"})
        assert run.status == :pending
      end

      # 4th run should fail limiter check
      result = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-4")
      assert {:error, %Error{code: :max_runs_exceeded}} = result
    end

    test "releasing a run allows new runs", %{store: store, adapter: adapter, limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Fill up
      for i <- 1..3 do
        :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
        {:ok, _} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"})
      end

      # Can't create more
      assert {:error, _} = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-4")

      # Release one
      :ok = ConcurrencyLimiter.release_run_slot(limiter, "run-2")

      # Now can create
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-4")
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test 4"})
      assert run.status == :pending
    end
  end

  # ============================================================================
  # Control Operations Integration Tests
  # ============================================================================

  describe "control operations with session manager" do
    test "cancel_run cancels via adapter and updates run status", %{
      store: store,
      adapter: adapter,
      ops: ops
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"})

      # Register run with control ops
      :ok = ControlOperations.register_run(ops, session.id, run.id)

      # Set run to running
      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      # Cancel via ControlOperations
      {:ok, _} = ControlOperations.cancel(ops, run.id)

      # Verify status tracked
      status = ControlOperations.get_operation_status(ops, run.id)
      assert status.state == :cancelled
      assert status.last_operation == :cancel
    end

    test "interrupt_session interrupts all runs for a session", %{
      store: store,
      adapter: adapter,
      ops: ops
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Create multiple runs
      runs =
        for i <- 1..3 do
          {:ok, run} =
            SessionManager.start_run(store, adapter, session.id, %{prompt: "Test #{i}"})

          :ok = ControlOperations.register_run(ops, session.id, run.id)
          run
        end

      # Interrupt all runs in session
      results = ControlOperations.interrupt_session(ops, session.id)

      # Verify all were interrupted
      assert map_size(results) == 3
      assert Enum.all?(results, fn {_, result} -> result == :ok end)

      # Verify each run's status
      for run <- runs do
        status = ControlOperations.get_operation_status(ops, run.id)
        assert status.state == :interrupted
      end
    end
  end

  # ============================================================================
  # Combined Flow Tests
  # ============================================================================

  describe "complete session flow with limits and control ops" do
    test "full session lifecycle respects limits and allows cancellation", %{
      store: store,
      adapter: adapter,
      limiter: limiter,
      ops: ops
    } do
      # 1. Acquire session slot
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "my-session")

      # 2. Create session
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "my-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # 3. Create and track run
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "my-session", "my-run")
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      :ok = ControlOperations.register_run(ops, session.id, run.id)

      # 4. Verify status
      limiter_status = ConcurrencyLimiter.get_status(limiter)
      assert limiter_status.active_sessions == 1
      assert limiter_status.active_runs == 1

      # 5. Cancel the run
      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)
      {:ok, _} = ControlOperations.cancel(ops, run.id)

      # 6. Release resources
      :ok = ConcurrencyLimiter.release_run_slot(limiter, "my-run")
      :ok = ConcurrencyLimiter.release_session_slot(limiter, "my-session")

      # 7. Verify cleanup
      limiter_status = ConcurrencyLimiter.get_status(limiter)
      assert limiter_status.active_sessions == 0
      assert limiter_status.active_runs == 0

      # 8. Verify operation history
      history = ControlOperations.get_operation_history(ops, run.id)
      assert length(history) == 1
      assert hd(history).operation == :cancel
    end
  end
end
