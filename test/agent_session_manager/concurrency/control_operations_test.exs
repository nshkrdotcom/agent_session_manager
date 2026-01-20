defmodule AgentSessionManager.Concurrency.ControlOperationsTest do
  @moduledoc """
  Tests for control operations (interrupt, cancel, pause/resume).

  These tests follow TDD methodology - tests are written first to specify
  the behavior of control operations before implementation.

  ## Test Categories

  1. Interrupt operations across adapters
  2. Cancel operations and idempotency
  3. Pause/resume operations with capability checking
  4. Control operation status tracking
  """

  use ExUnit.Case, async: true

  alias AgentSessionManager.Concurrency.ControlOperations
  alias AgentSessionManager.Core.{Capability, Error}

  # ============================================================================
  # Mock Adapter for Control Operations Tests
  # ============================================================================

  defmodule MockControlAdapter do
    @moduledoc """
    Mock adapter that tracks control operations for testing.
    """

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer

    alias AgentSessionManager.Core.{Capability, Error}

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(opts) do
      state = %{
        capabilities: Keyword.get(opts, :capabilities, default_capabilities()),
        interrupt_calls: [],
        cancel_calls: [],
        pause_calls: [],
        resume_calls: [],
        fail_on: Keyword.get(opts, :fail_on, []),
        # Track which runs are in which state
        run_states: %{}
      }

      {:ok, state}
    end

    defp default_capabilities do
      [
        %Capability{name: "interrupt", type: :sampling, enabled: true},
        %Capability{name: "cancel", type: :sampling, enabled: true}
      ]
    end

    # Behaviour callbacks
    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "mock_control"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts})
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id), do: GenServer.call(adapter, {:cancel, run_id})

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    # Extended control operations
    def interrupt(adapter, run_id), do: GenServer.call(adapter, {:interrupt, run_id})
    def pause(adapter, run_id), do: GenServer.call(adapter, {:pause, run_id})
    def resume(adapter, run_id), do: GenServer.call(adapter, {:resume, run_id})

    # Test helpers
    def get_calls(adapter, operation), do: GenServer.call(adapter, {:get_calls, operation})

    def set_run_state(adapter, run_id, state),
      do: GenServer.call(adapter, {:set_run_state, run_id, state})

    def set_capabilities(adapter, caps), do: GenServer.call(adapter, {:set_capabilities, caps})
    def set_fail_on(adapter, operations), do: GenServer.call(adapter, {:set_fail_on, operations})

    @impl GenServer
    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, state.capabilities}, state}
    end

    def handle_call({:execute, _run, _session, _opts}, _from, state) do
      {:reply, {:ok, %{output: %{}, token_usage: %{}, events: []}}, state}
    end

    def handle_call({:cancel, run_id}, _from, state) do
      if :cancel in state.fail_on do
        {:reply, {:error, Error.new(:provider_error, "Cancel failed")}, state}
      else
        new_calls = state.cancel_calls ++ [{run_id, DateTime.utc_now()}]
        new_states = Map.put(state.run_states, run_id, :cancelled)
        {:reply, {:ok, run_id}, %{state | cancel_calls: new_calls, run_states: new_states}}
      end
    end

    def handle_call({:interrupt, run_id}, _from, state) do
      if :interrupt in state.fail_on do
        {:reply, {:error, Error.new(:provider_error, "Interrupt failed")}, state}
      else
        new_calls = state.interrupt_calls ++ [{run_id, DateTime.utc_now()}]
        new_states = Map.put(state.run_states, run_id, :interrupted)
        {:reply, {:ok, run_id}, %{state | interrupt_calls: new_calls, run_states: new_states}}
      end
    end

    def handle_call({:pause, run_id}, _from, state) do
      if :pause in state.fail_on do
        {:reply, {:error, Error.new(:provider_error, "Pause failed")}, state}
      else
        new_calls = state.pause_calls ++ [{run_id, DateTime.utc_now()}]
        new_states = Map.put(state.run_states, run_id, :paused)
        {:reply, {:ok, run_id}, %{state | pause_calls: new_calls, run_states: new_states}}
      end
    end

    def handle_call({:resume, run_id}, _from, state) do
      if :resume in state.fail_on do
        {:reply, {:error, Error.new(:provider_error, "Resume failed")}, state}
      else
        new_calls = state.resume_calls ++ [{run_id, DateTime.utc_now()}]
        new_states = Map.put(state.run_states, run_id, :running)
        {:reply, {:ok, run_id}, %{state | resume_calls: new_calls, run_states: new_states}}
      end
    end

    def handle_call({:get_calls, operation}, _from, state) do
      calls =
        case operation do
          :interrupt -> state.interrupt_calls
          :cancel -> state.cancel_calls
          :pause -> state.pause_calls
          :resume -> state.resume_calls
        end

      {:reply, calls, state}
    end

    def handle_call({:set_run_state, run_id, run_state}, _from, state) do
      new_states = Map.put(state.run_states, run_id, run_state)
      {:reply, :ok, %{state | run_states: new_states}}
    end

    def handle_call({:set_capabilities, caps}, _from, state) do
      {:reply, :ok, %{state | capabilities: caps}}
    end

    def handle_call({:set_fail_on, operations}, _from, state) do
      {:reply, :ok, %{state | fail_on: operations}}
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    {:ok, adapter} = MockControlAdapter.start_link()
    {:ok, ops} = ControlOperations.start_link(adapter: adapter)

    on_exit(fn ->
      if Process.alive?(ops), do: GenServer.stop(ops)
      if Process.alive?(adapter), do: GenServer.stop(adapter)
    end)

    {:ok, ops: ops, adapter: adapter}
  end

  # ============================================================================
  # Interrupt Operation Tests
  # ============================================================================

  describe "interrupt/2" do
    test "interrupts a running run", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      assert {:ok, "run-1"} = ControlOperations.interrupt(ops, "run-1")
    end

    test "is idempotent - interrupting already interrupted run succeeds", %{
      ops: ops,
      adapter: adapter
    } do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      # First interrupt
      assert {:ok, "run-1"} = ControlOperations.interrupt(ops, "run-1")
      # Second interrupt should also succeed (idempotent)
      assert {:ok, "run-1"} = ControlOperations.interrupt(ops, "run-1")

      # Should have been called twice at adapter level (or just once depending on implementation)
      calls = MockControlAdapter.get_calls(adapter, :interrupt)
      assert length(calls) >= 1
    end

    test "returns error when adapter fails to interrupt", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_fail_on(adapter, [:interrupt])

      result = ControlOperations.interrupt(ops, "run-1")

      assert {:error, %Error{}} = result
    end

    test "tracks interrupt operation status", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      {:ok, _} = ControlOperations.interrupt(ops, "run-1")

      status = ControlOperations.get_operation_status(ops, "run-1")

      assert status.last_operation == :interrupt
      assert status.state == :interrupted
    end
  end

  # ============================================================================
  # Cancel Operation Tests
  # ============================================================================

  describe "cancel/2" do
    test "cancels a running run", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      assert {:ok, "run-1"} = ControlOperations.cancel(ops, "run-1")
    end

    test "is idempotent - cancelling already cancelled run succeeds", %{
      ops: ops,
      adapter: adapter
    } do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      # First cancel
      assert {:ok, "run-1"} = ControlOperations.cancel(ops, "run-1")
      # Second cancel should also succeed (idempotent)
      assert {:ok, "run-1"} = ControlOperations.cancel(ops, "run-1")
    end

    test "cancelling a pending run succeeds", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :pending)

      assert {:ok, "run-1"} = ControlOperations.cancel(ops, "run-1")
    end

    test "returns error when adapter fails to cancel", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_fail_on(adapter, [:cancel])

      result = ControlOperations.cancel(ops, "run-1")

      assert {:error, %Error{}} = result
    end

    test "tracks cancel operation status", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      {:ok, _} = ControlOperations.cancel(ops, "run-1")

      status = ControlOperations.get_operation_status(ops, "run-1")

      assert status.last_operation == :cancel
      assert status.state == :cancelled
    end

    test "cancel is final - cannot resume after cancel", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      {:ok, _} = ControlOperations.cancel(ops, "run-1")

      result = ControlOperations.resume(ops, "run-1")

      assert {:error, %Error{code: :invalid_operation}} = result
    end
  end

  # ============================================================================
  # Pause Operation Tests
  # ============================================================================

  describe "pause/2" do
    test "pauses a running run when capability exists", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "pause", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      assert {:ok, "run-1"} = ControlOperations.pause(ops, "run-1")
    end

    test "is idempotent - pausing already paused run succeeds", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "pause", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      assert {:ok, "run-1"} = ControlOperations.pause(ops, "run-1")
      assert {:ok, "run-1"} = ControlOperations.pause(ops, "run-1")
    end

    test "returns error when pause capability not available", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        # No pause capability
        %Capability{name: "interrupt", type: :sampling, enabled: true}
      ])

      result = ControlOperations.pause(ops, "run-1")

      assert {:error, %Error{code: :capability_not_supported}} = result
    end

    test "tracks pause operation status", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "pause", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      {:ok, _} = ControlOperations.pause(ops, "run-1")

      status = ControlOperations.get_operation_status(ops, "run-1")

      assert status.last_operation == :pause
      assert status.state == :paused
    end
  end

  # ============================================================================
  # Resume Operation Tests
  # ============================================================================

  describe "resume/2" do
    test "resumes a paused run when capability exists", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "pause", type: :sampling, enabled: true},
        %Capability{name: "resume", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :paused)

      assert {:ok, "run-1"} = ControlOperations.resume(ops, "run-1")
    end

    test "is idempotent - resuming already running run succeeds", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "resume", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      # Resuming an already running run should succeed (idempotent)
      assert {:ok, "run-1"} = ControlOperations.resume(ops, "run-1")
    end

    test "returns error when resume capability not available", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "pause", type: :sampling, enabled: true}
        # No resume capability
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :paused)

      result = ControlOperations.resume(ops, "run-1")

      assert {:error, %Error{code: :capability_not_supported}} = result
    end

    test "cannot resume a cancelled run", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "resume", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      # First cancel the run through ControlOperations (this updates internal state)
      {:ok, _} = ControlOperations.cancel(ops, "run-1")

      # Now try to resume - should fail because run is in terminal state
      result = ControlOperations.resume(ops, "run-1")

      assert {:error, %Error{code: :invalid_operation}} = result
    end

    test "tracks resume operation status", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "resume", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :paused)

      {:ok, _} = ControlOperations.resume(ops, "run-1")

      status = ControlOperations.get_operation_status(ops, "run-1")

      assert status.last_operation == :resume
      assert status.state == :running
    end
  end

  # ============================================================================
  # Batch Operations Tests
  # ============================================================================

  describe "cancel_all/2" do
    test "cancels multiple runs", %{ops: ops, adapter: adapter} do
      for i <- 1..3 do
        MockControlAdapter.set_run_state(adapter, "run-#{i}", :running)
      end

      results = ControlOperations.cancel_all(ops, ["run-1", "run-2", "run-3"])

      assert results == %{
               "run-1" => :ok,
               "run-2" => :ok,
               "run-3" => :ok
             }
    end

    test "reports partial failures", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_run_state(adapter, "run-1", :running)
      MockControlAdapter.set_run_state(adapter, "run-2", :running)

      # Make cancel fail after first call
      # This is a simplified test - in reality we'd need more sophisticated failure injection

      results = ControlOperations.cancel_all(ops, ["run-1", "run-2"])

      # At minimum, should return results for all requested runs
      assert Map.has_key?(results, "run-1")
      assert Map.has_key?(results, "run-2")
    end
  end

  describe "interrupt_session/2" do
    test "interrupts all runs for a session", %{ops: ops, adapter: adapter} do
      # Register runs as belonging to a session
      ControlOperations.register_run(ops, "session-1", "run-1")
      ControlOperations.register_run(ops, "session-1", "run-2")

      MockControlAdapter.set_run_state(adapter, "run-1", :running)
      MockControlAdapter.set_run_state(adapter, "run-2", :running)

      results = ControlOperations.interrupt_session(ops, "session-1")

      assert results["run-1"] == :ok
      assert results["run-2"] == :ok
    end
  end

  # ============================================================================
  # State Tracking Tests
  # ============================================================================

  describe "get_operation_history/2" do
    test "returns history of operations for a run", %{ops: ops, adapter: adapter} do
      MockControlAdapter.set_capabilities(adapter, [
        %Capability{name: "pause", type: :sampling, enabled: true},
        %Capability{name: "resume", type: :sampling, enabled: true}
      ])

      MockControlAdapter.set_run_state(adapter, "run-1", :running)

      {:ok, _} = ControlOperations.pause(ops, "run-1")
      {:ok, _} = ControlOperations.resume(ops, "run-1")
      {:ok, _} = ControlOperations.cancel(ops, "run-1")

      history = ControlOperations.get_operation_history(ops, "run-1")

      assert length(history) == 3
      assert Enum.map(history, & &1.operation) == [:pause, :resume, :cancel]
    end
  end

  describe "is_terminal_state?/1" do
    test "cancelled is terminal" do
      assert ControlOperations.is_terminal_state?(:cancelled) == true
    end

    test "completed is terminal" do
      assert ControlOperations.is_terminal_state?(:completed) == true
    end

    test "failed is terminal" do
      assert ControlOperations.is_terminal_state?(:failed) == true
    end

    test "running is not terminal" do
      assert ControlOperations.is_terminal_state?(:running) == false
    end

    test "paused is not terminal" do
      assert ControlOperations.is_terminal_state?(:paused) == false
    end
  end
end
