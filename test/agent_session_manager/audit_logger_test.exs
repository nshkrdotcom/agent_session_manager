defmodule AgentSessionManager.AuditLoggerTest do
  @moduledoc """
  Tests for audit log persistence.

  Following TDD workflow: these tests specify expected behavior before implementation.
  Audit logs should persist events to SessionStore in append-only order.

  Uses Supertester for robust async testing and process isolation.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.AuditLogger
  alias AgentSessionManager.Core.{Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup ctx do
    {:ok, store} = setup_test_store(ctx)
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    :ok = SessionStore.save_session(store, session)
    {:ok, run} = Run.new(%{session_id: session.id})
    :ok = SessionStore.save_run(store, run)

    %{store: store, session: session, run: run}
  end

  # ============================================================================
  # Configuration Tests
  # ============================================================================

  describe "AuditLogger.enabled?/0" do
    test "returns true by default" do
      assert AuditLogger.enabled?() == true
    end

    test "returns false when disabled via set_enabled/1" do
      AuditLogger.set_enabled(false)
      assert AuditLogger.enabled?() == false
    end
  end

  describe "AuditLogger.set_enabled/1" do
    test "enables audit logging" do
      AuditLogger.set_enabled(true)
      assert AuditLogger.enabled?() == true
    end

    test "disables audit logging" do
      AuditLogger.set_enabled(false)
      assert AuditLogger.enabled?() == false
    end
  end

  # ============================================================================
  # Audit Event Types
  # ============================================================================

  describe "AuditLogger.log_run_started/3" do
    test "creates audit event with type :run_started", %{store: store, session: session, run: run} do
      :ok = AuditLogger.log_run_started(store, run, session)

      {:ok, events} = SessionStore.get_events(store, session.id)
      run_started_events = Enum.filter(events, &(&1.type == :run_started))

      assert length(run_started_events) == 1
      event = hd(run_started_events)
      assert event.session_id == session.id
      assert event.run_id == run.id
    end

    test "includes run and session metadata in event data", %{
      store: store,
      session: session,
      run: run
    } do
      :ok = AuditLogger.log_run_started(store, run, session)

      {:ok, events} = SessionStore.get_events(store, session.id)
      event = Enum.find(events, &(&1.type == :run_started))

      assert event.data.agent_id == session.agent_id
      assert event.data.run_status == :pending
    end

    test "does not log when audit logging is disabled", %{
      store: store,
      session: session,
      run: run
    } do
      AuditLogger.set_enabled(false)

      :ok = AuditLogger.log_run_started(store, run, session)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.empty?(events)
    end
  end

  describe "AuditLogger.log_run_completed/4" do
    test "creates audit event with type :run_completed", %{
      store: store,
      session: session,
      run: run
    } do
      result = %{output: %{content: "Done"}, token_usage: %{input_tokens: 10, output_tokens: 5}}

      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = SessionStore.get_events(store, session.id)
      run_completed_events = Enum.filter(events, &(&1.type == :run_completed))

      assert length(run_completed_events) == 1
    end

    test "includes token usage in event data", %{store: store, session: session, run: run} do
      result = %{output: %{}, token_usage: %{input_tokens: 100, output_tokens: 50}}

      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = SessionStore.get_events(store, session.id)
      event = Enum.find(events, &(&1.type == :run_completed))

      assert event.data.token_usage.input_tokens == 100
      assert event.data.token_usage.output_tokens == 50
    end

    test "does not log when audit logging is disabled", %{
      store: store,
      session: session,
      run: run
    } do
      AuditLogger.set_enabled(false)

      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.empty?(events)
    end
  end

  describe "AuditLogger.log_run_failed/4" do
    test "creates audit event with type :run_failed", %{store: store, session: session, run: run} do
      error = %{code: :provider_error, message: "API failed"}

      :ok = AuditLogger.log_run_failed(store, run, session, error)

      {:ok, events} = SessionStore.get_events(store, session.id)
      run_failed_events = Enum.filter(events, &(&1.type == :run_failed))

      assert length(run_failed_events) == 1
    end

    test "includes error details in event data", %{store: store, session: session, run: run} do
      error = %{code: :rate_limit, message: "Too many requests"}

      :ok = AuditLogger.log_run_failed(store, run, session, error)

      {:ok, events} = SessionStore.get_events(store, session.id)
      event = Enum.find(events, &(&1.type == :run_failed))

      assert event.data.error_code == :rate_limit
      assert event.data.error_message == "Too many requests"
    end

    test "does not log when audit logging is disabled", %{
      store: store,
      session: session,
      run: run
    } do
      AuditLogger.set_enabled(false)

      error = %{code: :error, message: "Error"}
      :ok = AuditLogger.log_run_failed(store, run, session, error)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.empty?(events)
    end
  end

  describe "AuditLogger.log_error/4" do
    test "creates audit event with type :error_occurred", %{
      store: store,
      session: session,
      run: run
    } do
      error = %{code: :timeout, message: "Request timed out"}

      :ok = AuditLogger.log_error(store, run, session, error)

      {:ok, events} = SessionStore.get_events(store, session.id)
      error_events = Enum.filter(events, &(&1.type == :error_occurred))

      assert length(error_events) == 1
    end

    test "includes error details in event data", %{store: store, session: session, run: run} do
      error = %{
        code: :network_error,
        message: "Connection refused",
        details: %{host: "api.example.com"}
      }

      :ok = AuditLogger.log_error(store, run, session, error)

      {:ok, events} = SessionStore.get_events(store, session.id)
      event = Enum.find(events, &(&1.type == :error_occurred))

      assert event.data.error_code == :network_error
      assert event.data.error_message == "Connection refused"
    end
  end

  # ============================================================================
  # Append-Only Order Tests
  # ============================================================================

  describe "append-only order" do
    test "events are persisted in append order", %{store: store, session: session, run: run} do
      # Log multiple events
      :ok = AuditLogger.log_run_started(store, run, session)

      # Ensure timestamps differ
      Process.sleep(10)

      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = SessionStore.get_events(store, session.id)

      # Verify order is preserved (run_started before run_completed)
      types = Enum.map(events, & &1.type)
      started_idx = Enum.find_index(types, &(&1 == :run_started))
      completed_idx = Enum.find_index(types, &(&1 == :run_completed))

      assert started_idx < completed_idx
    end

    test "events have increasing timestamps", %{store: store, session: session, run: run} do
      :ok = AuditLogger.log_run_started(store, run, session)
      Process.sleep(10)
      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = SessionStore.get_events(store, session.id)

      timestamps = Enum.map(events, & &1.timestamp)
      pairs = Enum.zip(Enum.drop(timestamps, -1), Enum.drop(timestamps, 1))

      for {earlier, later} <- pairs do
        assert DateTime.compare(earlier, later) in [:lt, :eq]
      end
    end

    test "events cannot be modified after persistence", %{
      store: store,
      session: session,
      run: run
    } do
      :ok = AuditLogger.log_run_started(store, run, session)

      {:ok, [event]} = SessionStore.get_events(store, session.id)
      original_id = event.id

      # Append same event again (should be idempotent, not create duplicate)
      :ok = SessionStore.append_event(store, event)

      {:ok, events} = SessionStore.get_events(store, session.id)

      # Should still only have one event with that ID
      matching_events = Enum.filter(events, &(&1.id == original_id))
      assert length(matching_events) == 1
    end

    test "multiple runs create separate audit trails", %{store: store, session: session} do
      # Create two runs
      {:ok, run1} = Run.new(%{session_id: session.id})
      {:ok, run2} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run1)
      :ok = SessionStore.save_run(store, run2)

      # Log events for both runs
      :ok = AuditLogger.log_run_started(store, run1, session)
      :ok = AuditLogger.log_run_started(store, run2, session)

      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run1, session, result)
      :ok = AuditLogger.log_run_completed(store, run2, session, result)

      # Filter events by run_id
      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run1.id)
      run1_events = events

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run2.id)
      run2_events = events

      assert length(run1_events) == 2
      assert length(run2_events) == 2
      assert Enum.all?(run1_events, &(&1.run_id == run1.id))
      assert Enum.all?(run2_events, &(&1.run_id == run2.id))
    end
  end

  # ============================================================================
  # Usage Metrics Audit Tests
  # ============================================================================

  describe "AuditLogger.log_usage_metrics/3" do
    test "creates audit event with type :token_usage_updated", %{
      store: store,
      session: session,
      run: run
    } do
      metrics = %{input_tokens: 500, output_tokens: 200, total_tokens: 700}

      :ok = AuditLogger.log_usage_metrics(store, session, metrics, run_id: run.id)

      {:ok, events} = SessionStore.get_events(store, session.id)
      usage_events = Enum.filter(events, &(&1.type == :token_usage_updated))

      assert length(usage_events) == 1
    end

    test "includes all usage metrics in event data", %{store: store, session: session, run: run} do
      metrics = %{
        input_tokens: 500,
        output_tokens: 200,
        total_tokens: 700,
        cost_usd: 0.0035
      }

      :ok = AuditLogger.log_usage_metrics(store, session, metrics, run_id: run.id)

      {:ok, events} = SessionStore.get_events(store, session.id)
      event = Enum.find(events, &(&1.type == :token_usage_updated))

      assert event.data.input_tokens == 500
      assert event.data.output_tokens == 200
      assert event.data.total_tokens == 700
      assert event.data.cost_usd == 0.0035
    end

    test "does not log when audit logging is disabled", %{
      store: store,
      session: session,
      run: run
    } do
      AuditLogger.set_enabled(false)

      metrics = %{total_tokens: 100}
      :ok = AuditLogger.log_usage_metrics(store, session, metrics, run_id: run.id)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.empty?(events)
    end
  end

  # ============================================================================
  # Query Audit Log Tests
  # ============================================================================

  describe "AuditLogger.get_audit_log/3" do
    test "returns all audit events for a session", %{store: store, session: session, run: run} do
      :ok = AuditLogger.log_run_started(store, run, session)
      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = AuditLogger.get_audit_log(store, session.id)

      assert length(events) == 2
    end

    test "filters by run_id", %{store: store, session: session} do
      {:ok, run1} = Run.new(%{session_id: session.id})
      {:ok, run2} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run1)
      :ok = SessionStore.save_run(store, run2)

      :ok = AuditLogger.log_run_started(store, run1, session)
      :ok = AuditLogger.log_run_started(store, run2, session)

      {:ok, events} = AuditLogger.get_audit_log(store, session.id, run_id: run1.id)

      assert length(events) == 1
      assert hd(events).run_id == run1.id
    end

    test "filters by event type", %{store: store, session: session, run: run} do
      :ok = AuditLogger.log_run_started(store, run, session)
      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = AuditLogger.get_audit_log(store, session.id, type: :run_started)

      assert length(events) == 1
      assert hd(events).type == :run_started
    end

    test "filters by timestamp (since)", %{store: store, session: session, run: run} do
      :ok = AuditLogger.log_run_started(store, run, session)

      # Wait and capture the time
      Process.sleep(10)
      since = DateTime.utc_now()
      Process.sleep(10)

      result = %{output: %{}, token_usage: %{}}
      :ok = AuditLogger.log_run_completed(store, run, session, result)

      {:ok, events} = AuditLogger.get_audit_log(store, session.id, since: since)

      # Should only get the completed event
      assert length(events) == 1
      assert hd(events).type == :run_completed
    end
  end

  # ============================================================================
  # Integration with Telemetry Tests
  # ============================================================================

  describe "AuditLogger.attach_telemetry_handlers/1" do
    test "automatically logs audit events from telemetry", %{
      store: store,
      session: session,
      run: run
    } do
      # Attach handlers
      :ok = AuditLogger.attach_telemetry_handlers(store)

      # Emit telemetry event (simulating what the Telemetry module does)
      :telemetry.execute(
        [:agent_session_manager, :run, :start],
        %{system_time: System.system_time()},
        %{
          run_id: run.id,
          session_id: session.id,
          agent_id: session.agent_id,
          run: run,
          session: session
        }
      )

      # Give it time to process
      Process.sleep(50)

      {:ok, events} = SessionStore.get_events(store, session.id)

      # Should have logged the run_started event
      assert Enum.any?(events, &(&1.type == :run_started))

      # Detach handlers to clean up
      AuditLogger.detach_telemetry_handlers()
    end
  end
end
