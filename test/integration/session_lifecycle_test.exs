defmodule AgentSessionManager.Integration.SessionLifecycleTest do
  @moduledoc """
  End-to-end integration tests for the full session lifecycle.

  These tests verify the complete flow from session creation through
  completion, including:
  - Session creation and activation
  - Run creation, execution, and completion
  - Event emission and persistence
  - Capability negotiation
  - Error handling and recovery
  - Cancellation flows
  - Multi-run sessions

  All tests use mock adapters and are deterministic and parallel-safe.
  """

  use ExUnit.Case, async: true

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Core.{Error, Run, Session}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Test.{Fixtures, MockProviderAdapter}

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    {:ok, store} = InMemorySessionStore.start_link()

    {:ok, adapter} =
      MockProviderAdapter.start_link(
        capabilities: Fixtures.provider_capabilities(:full_claude),
        execution_mode: :instant
      )

    on_exit(fn ->
      for pid <- [store, adapter] do
        if is_pid(pid) and Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    {:ok, store: store, adapter: adapter}
  end

  # ============================================================================
  # Happy Path Integration Tests
  # ============================================================================

  describe "happy path: simple session lifecycle" do
    test "creates session, activates, runs, and completes", %{store: store, adapter: adapter} do
      # 1. Create session
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "integration-test-agent",
          metadata: %{test_run: true}
        })

      assert session.status == :pending
      assert session.agent_id == "integration-test-agent"

      # 2. Verify session is persisted
      {:ok, persisted_session} = SessionStore.get_session(store, session.id)
      assert persisted_session.id == session.id

      # 3. Activate session
      {:ok, activated} = SessionManager.activate_session(store, session.id)
      assert activated.status == :active

      # 4. Create and execute a run
      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{
          messages: [%{role: "user", content: "Hello!"}]
        })

      assert run.status == :pending
      assert run.session_id == session.id

      # 5. Execute the run
      {:ok, result} = SessionManager.execute_run(store, adapter, run.id)
      assert is_map(result.output)
      assert is_map(result.token_usage)

      # 6. Verify run is completed
      {:ok, completed_run} = SessionStore.get_run(store, run.id)
      assert completed_run.status == :completed

      # 7. Complete session
      {:ok, completed_session} = SessionManager.complete_session(store, session.id)
      assert completed_session.status == :completed

      # 8. Verify events were emitted
      {:ok, events} = SessionStore.get_events(store, session.id)

      event_types = Enum.map(events, & &1.type)
      assert :session_created in event_types
      assert :session_started in event_types
      assert :run_started in event_types
      assert :message_received in event_types
      assert :run_completed in event_types
      assert :session_completed in event_types
    end

    test "full lifecycle with streaming execution mode", %{store: store, adapter: adapter} do
      # Configure streaming mode
      MockProviderAdapter.set_execution_mode(adapter, :streaming)

      MockProviderAdapter.set_response(adapter, :execute, %{
        output: %{content: "Hello! How can I help you?", stop_reason: "end_turn", tool_calls: []},
        token_usage: %{input_tokens: 10, output_tokens: 15},
        events: []
      })

      # Create and activate session
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "streaming-agent"})

      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Track events via callback
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      # Create run
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hi"})

      # Execute with callback - but we need to call execute directly on adapter
      # since SessionManager doesn't expose the callback directly through execute_run
      {:ok, result} = MockProviderAdapter.execute(adapter, run, session, event_callback: callback)

      assert result.output.content == "Hello! How can I help you?"

      # Collect streamed events
      events = collect_events_with_timeout(100)

      # Should have streaming events
      event_types = Enum.map(events, & &1.type)
      assert :run_started in event_types
      assert :message_streamed in event_types
      assert :message_received in event_types
      assert :run_completed in event_types
    end
  end

  # ============================================================================
  # Multi-Run Session Tests
  # ============================================================================

  describe "multi-run sessions" do
    test "executes multiple runs in a single session", %{store: store, adapter: adapter} do
      # Create and activate session
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "multi-run-agent"})

      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Execute multiple runs
      run_count = 3

      runs =
        for i <- 1..run_count do
          {:ok, run} =
            SessionManager.start_run(store, adapter, session.id, %{prompt: "Message #{i}"})

          {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)
          run
        end

      # Verify all runs completed
      {:ok, all_runs} = SessionStore.list_runs(store, session.id)
      assert length(all_runs) == run_count

      # All should be completed
      assert Enum.all?(all_runs, fn run ->
               {:ok, r} = SessionStore.get_run(store, run.id)
               r.status == :completed
             end)

      # Verify execution history
      history = MockProviderAdapter.get_execution_history(adapter)
      assert length(history) == run_count

      # Verify events for each run
      for run <- runs do
        {:ok, run_events} = SessionStore.get_events(store, session.id, run_id: run.id)
        assert length(run_events) >= 2
      end
    end

    test "tracks cumulative token usage across runs", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "token-tracking"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Configure predictable token usage
      MockProviderAdapter.set_response(adapter, :execute, %{
        output: %{content: "Response", stop_reason: "end_turn", tool_calls: []},
        token_usage: %{input_tokens: 10, output_tokens: 20},
        events: []
      })

      # Execute runs
      for _ <- 1..3 do
        {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"})
        {:ok, _} = SessionManager.execute_run(store, adapter, run.id)
      end

      # Verify each run has token usage
      {:ok, all_runs} = SessionStore.list_runs(store, session.id)

      for run <- all_runs do
        {:ok, completed_run} = SessionStore.get_run(store, run.id)
        assert completed_run.token_usage.input_tokens == 10
        assert completed_run.token_usage.output_tokens == 20
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles provider errors gracefully", %{store: store, adapter: adapter} do
      # Configure adapter to fail
      error = Error.new(:provider_error, "API error occurred")
      MockProviderAdapter.set_fail_with(adapter, error)

      # Create session
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "error-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Clear the failure for session creation, set it for run execution
      MockProviderAdapter.clear_fail_with(adapter)

      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"})

      # Now fail execution
      MockProviderAdapter.set_fail_with(adapter, error)

      {:error, returned_error} = SessionManager.execute_run(store, adapter, run.id)

      assert returned_error.code == :provider_error

      # Run should be marked as failed
      {:ok, failed_run} = SessionStore.get_run(store, run.id)
      assert failed_run.status == :failed

      # Should have run_failed event
      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert Enum.any?(events, &(&1.type == :run_failed))
    end

    test "handles session failure", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "fail-session"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Fail the session
      error = Error.new(:internal_error, "Something went wrong")
      {:ok, failed_session} = SessionManager.fail_session(store, session.id, error)

      assert failed_session.status == :failed

      # Verify event
      {:ok, events} = SessionStore.get_events(store, session.id)
      failed_event = Enum.find(events, &(&1.type == :session_failed))
      assert failed_event != nil
      assert failed_event.data.error_code == :internal_error
    end

    test "validates session_id requirement", %{store: store, adapter: adapter} do
      result = SessionManager.start_session(store, adapter, %{})
      assert {:error, %Error{code: :validation_error}} = result
    end

    test "returns error for non-existent session", %{store: store} do
      result = SessionManager.get_session(store, "non_existent_id")
      assert {:error, %Error{code: :session_not_found}} = result
    end

    test "returns error for non-existent run", %{store: store, adapter: adapter} do
      result = SessionManager.execute_run(store, adapter, "non_existent_run")
      assert {:error, %Error{code: :run_not_found}} = result
    end
  end

  # ============================================================================
  # Cancellation Tests
  # ============================================================================

  describe "cancellation" do
    test "cancels an in-progress run", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "cancel-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Long task"})

      # Set run to running
      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      # Cancel the run
      {:ok, cancelled_id} = SessionManager.cancel_run(store, adapter, run.id)

      assert cancelled_id == run.id

      # Verify run is cancelled
      {:ok, cancelled_run} = SessionStore.get_run(store, run.id)
      assert cancelled_run.status == :cancelled

      # Verify event
      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert Enum.any?(events, &(&1.type == :run_cancelled))

      # Verify adapter was notified
      cancelled_runs = MockProviderAdapter.get_cancelled_runs(adapter)
      assert run.id in cancelled_runs
    end
  end

  # ============================================================================
  # Capability Negotiation Tests
  # ============================================================================

  describe "capability negotiation" do
    test "allows run when required capabilities are present", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "cap-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Require :tool and :sampling (both should be present in full_claude)
      opts = [required_capabilities: [:tool, :sampling]]

      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"}, opts)

      assert %Run{} = run
    end

    test "rejects run when required capability is missing", %{store: store, adapter: adapter} do
      # Set minimal capabilities (no file_access)
      MockProviderAdapter.set_capabilities(adapter, Fixtures.provider_capabilities(:minimal))

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "cap-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Require file_access (not present)
      opts = [required_capabilities: [:file_access]]

      result = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"}, opts)

      assert {:error, %Error{code: :missing_required_capability}} = result
    end

    test "allows run when optional capabilities are missing", %{store: store, adapter: adapter} do
      MockProviderAdapter.set_capabilities(adapter, Fixtures.provider_capabilities(:minimal))

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "cap-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Optional file_access (not present but should still work)
      opts = [optional_capabilities: [:file_access]]

      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"}, opts)

      assert %Run{} = run
    end
  end

  # ============================================================================
  # Event Verification Tests
  # ============================================================================

  describe "event persistence and ordering" do
    test "events are stored in order", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "event-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)
      {:ok, _} = SessionManager.complete_session(store, session.id)

      {:ok, events} = SessionStore.get_events(store, session.id)

      # Events should be in chronological order
      timestamps = Enum.map(events, & &1.timestamp)
      sorted_timestamps = Enum.sort(timestamps, DateTime)

      assert timestamps == sorted_timestamps

      # Verify event sequence
      event_types = Enum.map(events, & &1.type)

      # session_created should come first
      assert hd(event_types) == :session_created

      # session_completed should come last
      assert List.last(event_types) == :session_completed

      # run_started should come before run_completed
      run_start_idx = Enum.find_index(event_types, &(&1 == :run_started))
      run_complete_idx = Enum.find_index(event_types, &(&1 == :run_completed))

      if run_start_idx && run_complete_idx do
        assert run_start_idx < run_complete_idx
      end
    end

    test "events can be filtered by run_id", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "filter-test"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Create two runs
      {:ok, run1} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Run 1"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run1.id)

      {:ok, run2} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Run 2"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run2.id)

      # Get events for run1 only
      {:ok, run1_events} = SessionStore.get_events(store, session.id, run_id: run1.id)

      assert Enum.all?(run1_events, &(&1.run_id == run1.id))
      assert length(run1_events) >= 2

      # Get events for run2 only
      {:ok, run2_events} = SessionStore.get_events(store, session.id, run_id: run2.id)

      assert Enum.all?(run2_events, &(&1.run_id == run2.id))
      assert length(run2_events) >= 2
    end

    test "events can be filtered by type", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "type-filter"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Test"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, message_events} =
        SessionStore.get_events(store, session.id, type: :message_received)

      assert Enum.all?(message_events, &(&1.type == :message_received))
    end
  end

  # ============================================================================
  # Concurrent Access Tests
  # ============================================================================

  describe "concurrent access safety" do
    test "handles concurrent session creation", %{adapter: adapter} do
      # Start multiple stores for isolation
      stores =
        for _ <- 1..5 do
          {:ok, store} = InMemorySessionStore.start_link()
          store
        end

      # Create sessions concurrently
      tasks =
        for {store, idx} <- Enum.with_index(stores) do
          Task.async(fn ->
            SessionManager.start_session(store, adapter, %{
              agent_id: "concurrent-agent-#{idx}"
            })
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, %Session{}} -> true
               _ -> false
             end)

      # All sessions should have unique IDs
      session_ids =
        results
        |> Enum.map(fn {:ok, session} -> session.id end)
        |> Enum.uniq()

      assert length(session_ids) == length(stores)

      # Cleanup
      for store <- stores do
        try do
          InMemorySessionStore.stop(store)
        catch
          :exit, _ -> :ok
        end
      end
    end

    test "handles concurrent run creation within a session", %{store: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "concurrent-runs"})

      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Create runs concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            SessionManager.start_run(store, adapter, session.id, %{prompt: "Concurrent #{i}"})
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, %Run{}} -> true
               _ -> false
             end)

      # Verify all runs are stored
      {:ok, all_runs} = SessionStore.list_runs(store, session.id)
      assert length(all_runs) == 10
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp collect_events_with_timeout(timeout_ms) do
    collect_events([], timeout_ms)
  end

  defp collect_events(acc, timeout_ms) do
    receive do
      {:event, event} ->
        collect_events(acc ++ [event], timeout_ms)
    after
      timeout_ms ->
        acc
    end
  end
end
