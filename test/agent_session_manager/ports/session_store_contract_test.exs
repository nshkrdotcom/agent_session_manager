defmodule AgentSessionManager.Ports.SessionStoreContractTest do
  @moduledoc """
  Contract tests for SessionStore behaviour.

  These tests define the expected behaviour of any SessionStore implementation.
  They should be run against all implementations to ensure compliance.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  # Helper to get a fresh store for each test
  defp new_store do
    {:ok, store} = InMemorySessionStore.start_link([])
    store
  end

  describe "Session operations" do
    test "save_session/2 stores a new session" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})

      assert :ok = SessionStore.save_session(store, session)
    end

    test "get_session/2 retrieves a stored session" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)

      assert retrieved.id == session.id
      assert retrieved.agent_id == session.agent_id
      assert retrieved.status == session.status
    end

    test "get_session/2 returns error for non-existent session" do
      store = new_store()

      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, "non-existent-id")
    end

    test "save_session/2 updates existing session (idempotent write)" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)

      {:ok, updated} = Session.update_status(session, :active)
      :ok = SessionStore.save_session(store, updated)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.status == :active
    end

    test "save_session/2 is idempotent for same version" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})

      # Save same session multiple times
      assert :ok = SessionStore.save_session(store, session)
      assert :ok = SessionStore.save_session(store, session)
      assert :ok = SessionStore.save_session(store, session)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.id == session.id
    end

    test "list_sessions/2 returns all sessions" do
      store = new_store()
      {:ok, session1} = Session.new(%{agent_id: "agent-1"})
      {:ok, session2} = Session.new(%{agent_id: "agent-2"})

      :ok = SessionStore.save_session(store, session1)
      :ok = SessionStore.save_session(store, session2)

      {:ok, sessions} = SessionStore.list_sessions(store)

      assert length(sessions) == 2
      ids = Enum.map(sessions, & &1.id)
      assert session1.id in ids
      assert session2.id in ids
    end

    test "list_sessions/2 with status filter" do
      store = new_store()
      {:ok, session1} = Session.new(%{agent_id: "agent-1"})
      {:ok, session2} = Session.new(%{agent_id: "agent-2"})
      {:ok, session2_active} = Session.update_status(session2, :active)

      :ok = SessionStore.save_session(store, session1)
      :ok = SessionStore.save_session(store, session2_active)

      {:ok, pending} = SessionStore.list_sessions(store, status: :pending)
      {:ok, active} = SessionStore.list_sessions(store, status: :active)

      assert length(pending) == 1
      assert length(active) == 1
      assert hd(pending).id == session1.id
      assert hd(active).id == session2.id
    end

    test "delete_session/2 removes a session" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)

      assert :ok = SessionStore.delete_session(store, session.id)

      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, session.id)
    end

    test "delete_session/2 is idempotent" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)

      assert :ok = SessionStore.delete_session(store, session.id)
      assert :ok = SessionStore.delete_session(store, session.id)
    end
  end

  describe "Run operations" do
    setup do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)
      {:ok, store: store, session: session}
    end

    test "save_run/2 stores a new run", %{store: store, session: session} do
      {:ok, run} = Run.new(%{session_id: session.id})

      assert :ok = SessionStore.save_run(store, run)
    end

    test "get_run/2 retrieves a stored run", %{store: store, session: session} do
      {:ok, run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run)

      {:ok, retrieved} = SessionStore.get_run(store, run.id)

      assert retrieved.id == run.id
      assert retrieved.session_id == session.id
      assert retrieved.status == :pending
    end

    test "get_run/2 returns error for non-existent run", %{store: store} do
      assert {:error, %Error{code: :run_not_found}} =
               SessionStore.get_run(store, "non-existent-id")
    end

    test "save_run/2 updates existing run", %{store: store, session: session} do
      {:ok, run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run)

      {:ok, running} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running)

      {:ok, retrieved} = SessionStore.get_run(store, run.id)
      assert retrieved.status == :running
    end

    test "list_runs/2 returns all runs for a session", %{store: store, session: session} do
      {:ok, run1} = Run.new(%{session_id: session.id})
      {:ok, run2} = Run.new(%{session_id: session.id})

      :ok = SessionStore.save_run(store, run1)
      :ok = SessionStore.save_run(store, run2)

      {:ok, runs} = SessionStore.list_runs(store, session.id)

      assert length(runs) == 2
      ids = Enum.map(runs, & &1.id)
      assert run1.id in ids
      assert run2.id in ids
    end

    test "list_runs/2 returns empty list for session with no runs", %{store: store} do
      {:ok, other_session} = Session.new(%{agent_id: "agent-other"})
      :ok = SessionStore.save_session(store, other_session)

      {:ok, runs} = SessionStore.list_runs(store, other_session.id)
      assert runs == []
    end

    test "get_active_run/2 returns currently running run", %{store: store, session: session} do
      {:ok, run} = Run.new(%{session_id: session.id})
      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      {:ok, active} = SessionStore.get_active_run(store, session.id)
      assert active.id == run.id
      assert active.status == :running
    end

    test "get_active_run/2 returns nil when no active run", %{store: store, session: session} do
      {:ok, run} = Run.new(%{session_id: session.id})
      {:ok, completed_run} = Run.update_status(run, :completed)
      :ok = SessionStore.save_run(store, completed_run)

      assert {:ok, nil} = SessionStore.get_active_run(store, session.id)
    end

    test "provides read-after-write consistency for active runs", %{
      store: store,
      session: session
    } do
      {:ok, run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run)

      # Immediately update to running
      {:ok, running} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running)

      # Should immediately see the running status
      {:ok, active} = SessionStore.get_active_run(store, session.id)
      assert active.status == :running
    end
  end

  describe "Event operations" do
    setup do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)
      {:ok, run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run)
      {:ok, store: store, session: session, run: run}
    end

    test "append_event/2 stores an event", %{store: store, session: session} do
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})

      assert :ok = SessionStore.append_event(store, event)
    end

    test "get_events/2 retrieves events for a session", %{store: store, session: session} do
      {:ok, event1} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, event2} = Event.new(%{type: :session_started, session_id: session.id})

      :ok = SessionStore.append_event(store, event1)
      :ok = SessionStore.append_event(store, event2)

      {:ok, events} = SessionStore.get_events(store, session.id)

      assert length(events) == 2
    end

    test "events are returned in append order", %{store: store, session: session} do
      {:ok, event1} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, event2} = Event.new(%{type: :session_started, session_id: session.id})
      {:ok, event3} = Event.new(%{type: :run_started, session_id: session.id})

      :ok = SessionStore.append_event(store, event1)
      :ok = SessionStore.append_event(store, event2)
      :ok = SessionStore.append_event(store, event3)

      {:ok, events} = SessionStore.get_events(store, session.id)

      assert [first, second, third] = events
      assert first.type == :session_created
      assert second.type == :session_started
      assert third.type == :run_started
    end

    test "get_events/3 filters by run_id", %{store: store, session: session, run: run} do
      {:ok, session_event} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, run_event} = Event.new(%{type: :run_started, session_id: session.id, run_id: run.id})

      :ok = SessionStore.append_event(store, session_event)
      :ok = SessionStore.append_event(store, run_event)

      {:ok, run_events} = SessionStore.get_events(store, session.id, run_id: run.id)

      assert length(run_events) == 1
      assert hd(run_events).run_id == run.id
    end

    test "get_events/3 filters by event type", %{store: store, session: session} do
      {:ok, event1} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, event2} = Event.new(%{type: :session_started, session_id: session.id})
      {:ok, event3} = Event.new(%{type: :session_created, session_id: session.id})

      :ok = SessionStore.append_event(store, event1)
      :ok = SessionStore.append_event(store, event2)
      :ok = SessionStore.append_event(store, event3)

      {:ok, created_events} = SessionStore.get_events(store, session.id, type: :session_created)

      assert length(created_events) == 2
      assert Enum.all?(created_events, &(&1.type == :session_created))
    end

    test "events are immutable (append-only)", %{store: store, session: session} do
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})
      :ok = SessionStore.append_event(store, event)

      {:ok, [stored_event]} = SessionStore.get_events(store, session.id)

      # Events should maintain their original data
      assert stored_event.id == event.id
      assert stored_event.type == event.type
      assert stored_event.session_id == event.session_id
    end

    test "append_event_with_sequence/2 assigns increasing sequence numbers", %{
      store: store,
      session: session
    } do
      {:ok, event1} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, event2} = Event.new(%{type: :session_started, session_id: session.id})

      assert {:ok, stored1} = SessionStore.append_event_with_sequence(store, event1)
      assert {:ok, stored2} = SessionStore.append_event_with_sequence(store, event2)

      assert stored1.sequence_number == 1
      assert stored2.sequence_number == 2
      assert {:ok, 2} = SessionStore.get_latest_sequence(store, session.id)
    end

    test "append_event_with_sequence/2 is idempotent for duplicate IDs", %{
      store: store,
      session: session
    } do
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})

      assert {:ok, first} = SessionStore.append_event_with_sequence(store, event)
      assert {:ok, second} = SessionStore.append_event_with_sequence(store, event)

      assert first.id == second.id
      assert first.sequence_number == second.sequence_number

      assert {:ok, events} = SessionStore.get_events(store, session.id)
      assert length(events) == 1
      assert {:ok, 1} = SessionStore.get_latest_sequence(store, session.id)
    end

    test "append_events/2 assigns contiguous sequence numbers", %{
      store: store,
      session: session,
      run: run
    } do
      {:ok, event1} = Event.new(%{type: :run_started, session_id: session.id, run_id: run.id})

      {:ok, event2} =
        Event.new(%{type: :message_received, session_id: session.id, run_id: run.id})

      assert {:ok, [stored1, stored2]} = SessionStore.append_events(store, [event1, event2])
      assert stored1.sequence_number == 1
      assert stored2.sequence_number == 2
      assert {:ok, 2} = SessionStore.get_latest_sequence(store, session.id)
    end

    test "append_events/2 is idempotent for duplicate IDs", %{store: store, session: session} do
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})

      assert {:ok, [first, second]} = SessionStore.append_events(store, [event, event])
      assert first.id == second.id
      assert first.sequence_number == second.sequence_number

      assert {:ok, events} = SessionStore.get_events(store, session.id)
      assert length(events) == 1
      assert {:ok, 1} = SessionStore.get_latest_sequence(store, session.id)
    end

    test "get_latest_sequence/2 returns 0 for sessions without events", %{store: store} do
      {:ok, other_session} = Session.new(%{agent_id: "agent-other"})
      :ok = SessionStore.save_session(store, other_session)

      assert {:ok, 0} = SessionStore.get_latest_sequence(store, other_session.id)
    end

    test "get_events/3 supports :after and :before cursor filters", %{
      store: store,
      session: session,
      run: run
    } do
      {:ok, event1} = Event.new(%{type: :run_started, session_id: session.id, run_id: run.id})

      {:ok, event2} =
        Event.new(%{type: :message_received, session_id: session.id, run_id: run.id})

      {:ok, event3} = Event.new(%{type: :run_completed, session_id: session.id, run_id: run.id})

      {:ok, stored_event1} = SessionStore.append_event_with_sequence(store, event1)
      {:ok, _stored_event2} = SessionStore.append_event_with_sequence(store, event2)
      {:ok, stored_event3} = SessionStore.append_event_with_sequence(store, event3)

      assert {:ok, after_events} =
               SessionStore.get_events(store, session.id, after: stored_event1.sequence_number)

      assert Enum.map(after_events, & &1.sequence_number) == [2, 3]

      assert {:ok, before_events} =
               SessionStore.get_events(store, session.id, before: stored_event3.sequence_number)

      assert Enum.map(before_events, & &1.sequence_number) == [1, 2]

      assert {:ok, bounded_events} =
               SessionStore.get_events(
                 store,
                 session.id,
                 after: stored_event1.sequence_number,
                 before: stored_event3.sequence_number
               )

      assert Enum.map(bounded_events, & &1.sequence_number) == [2]
    end

    test "cursor filters compose with run_id, type, and limit", %{
      store: store,
      session: session
    } do
      {:ok, run1} = Run.new(%{session_id: session.id})
      {:ok, run2} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run1)
      :ok = SessionStore.save_run(store, run2)

      {:ok, event1} = Event.new(%{type: :run_started, session_id: session.id, run_id: run1.id})

      {:ok, event2} =
        Event.new(%{type: :message_received, session_id: session.id, run_id: run1.id})

      {:ok, event3} =
        Event.new(%{type: :message_received, session_id: session.id, run_id: run2.id})

      {:ok, event4} =
        Event.new(%{type: :message_received, session_id: session.id, run_id: run1.id})

      {:ok, event5} =
        Event.new(%{type: :message_received, session_id: session.id, run_id: run1.id})

      {:ok, event1} = SessionStore.append_event_with_sequence(store, event1)
      {:ok, event2} = SessionStore.append_event_with_sequence(store, event2)
      {:ok, _} = SessionStore.append_event_with_sequence(store, event3)
      {:ok, event4} = SessionStore.append_event_with_sequence(store, event4)
      {:ok, _} = SessionStore.append_event_with_sequence(store, event5)

      assert {:ok, filtered} =
               SessionStore.get_events(
                 store,
                 session.id,
                 after: event1.sequence_number,
                 run_id: run1.id,
                 type: :message_received,
                 limit: 2
               )

      assert Enum.map(filtered, & &1.sequence_number) == [
               event2.sequence_number,
               event4.sequence_number
             ]
    end
  end

  describe "Execution flush" do
    setup do
      store = new_store()
      {:ok, store: store}
    end

    test "flush/2 persists session, run, and events atomically", %{store: store} do
      {:ok, session} = Session.new(%{agent_id: "flush-agent"})
      {:ok, run} = Run.new(%{session_id: session.id})
      {:ok, run} = Run.update_status(run, :completed)

      {:ok, event1} =
        Event.new(%{
          type: :run_started,
          session_id: session.id,
          run_id: run.id
        })

      {:ok, event2} =
        Event.new(%{
          type: :run_completed,
          session_id: session.id,
          run_id: run.id
        })

      assert :ok =
               SessionStore.flush(store, %{
                 session: session,
                 run: run,
                 events: [event1, event2],
                 provider_metadata: %{}
               })

      assert {:ok, _stored_session} = SessionStore.get_session(store, session.id)
      assert {:ok, _stored_run} = SessionStore.get_run(store, run.id)
      assert {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert length(events) == 2
      assert Enum.map(events, & &1.type) == [:run_started, :run_completed]
    end

    test "flush/2 rolls back when events are invalid", %{store: store} do
      {:ok, session} = Session.new(%{agent_id: "flush-agent"})
      {:ok, run} = Run.new(%{session_id: session.id})

      assert {:error, %Error{code: :validation_error}} =
               SessionStore.flush(store, %{
                 session: session,
                 run: run,
                 events: [%{invalid: true}],
                 provider_metadata: %{}
               })

      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, session.id)

      assert {:error, %Error{code: :run_not_found}} = SessionStore.get_run(store, run.id)
    end
  end

  describe "Long-poll wait_timeout_ms" do
    setup do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)
      {:ok, store: store, session: session}
    end

    test "get_events/3 returns immediately when events exist (wait_timeout_ms ignored)", %{
      store: store,
      session: session
    } do
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      start = System.monotonic_time(:millisecond)

      {:ok, events} =
        SessionStore.get_events(store, session.id, after: 0, wait_timeout_ms: 5_000)

      elapsed = System.monotonic_time(:millisecond) - start

      assert length(events) == 1
      # Should return near-instantly, well under the 5s timeout
      assert elapsed < 1_000
    end

    test "get_events/3 with wait_timeout_ms blocks until event appended", %{
      store: store,
      session: session
    } do
      test_pid = self()

      # Start a reader that will block waiting for events
      reader_task =
        Task.async(fn ->
          send(test_pid, :reader_started)

          {:ok, events} =
            SessionStore.get_events(store, session.id, after: 0, wait_timeout_ms: 10_000)

          events
        end)

      # Wait for reader to start
      assert_receive :reader_started, 1_000

      # Give the reader time to enter the wait state
      Process.sleep(50)

      # Append an event — should unblock the reader
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      # Reader should return promptly with the new event
      events = Task.await(reader_task, 5_000)
      assert events != []
      assert hd(events).type == :session_created
    end

    test "get_events/3 with wait_timeout_ms returns empty list on timeout", %{
      store: store,
      session: session
    } do
      start = System.monotonic_time(:millisecond)

      {:ok, events} =
        SessionStore.get_events(store, session.id, after: 0, wait_timeout_ms: 100)

      elapsed = System.monotonic_time(:millisecond) - start

      assert events == []
      # Should have waited approximately the timeout duration
      assert elapsed >= 80
    end

    test "get_events/3 with wait_timeout_ms respects session filter", %{
      store: store,
      session: session
    } do
      # Create a second session
      {:ok, other_session} = Session.new(%{agent_id: "agent-other"})
      :ok = SessionStore.save_session(store, other_session)

      test_pid = self()

      reader_task =
        Task.async(fn ->
          send(test_pid, :reader_started)

          {:ok, events} =
            SessionStore.get_events(store, session.id, after: 0, wait_timeout_ms: 10_000)

          events
        end)

      assert_receive :reader_started, 1_000
      Process.sleep(50)

      # Append event to different session — should NOT unblock
      {:ok, other_event} = Event.new(%{type: :session_created, session_id: other_session.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, other_event)

      # Wait a bit, reader should still be blocked
      Process.sleep(100)
      refute Process.alive?(reader_task.pid) == false

      # Now append event to correct session — should unblock
      {:ok, event} = Event.new(%{type: :session_started, session_id: session.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      events = Task.await(reader_task, 5_000)
      assert events != []
      assert hd(events).session_id == session.id
    end

    test "get_events/3 with wait_timeout_ms respects type filter", %{
      store: store,
      session: session
    } do
      test_pid = self()

      reader_task =
        Task.async(fn ->
          send(test_pid, :reader_started)

          {:ok, events} =
            SessionStore.get_events(store, session.id,
              after: 0,
              type: :run_started,
              wait_timeout_ms: 10_000
            )

          events
        end)

      assert_receive :reader_started, 1_000
      Process.sleep(50)

      # Append non-matching event — should NOT unblock
      {:ok, created_event} = Event.new(%{type: :session_created, session_id: session.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, created_event)

      Process.sleep(100)

      # Append matching event — should unblock
      {:ok, run_event} = Event.new(%{type: :run_started, session_id: session.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, run_event)

      events = Task.await(reader_task, 5_000)
      assert events != []
      assert Enum.all?(events, &(&1.type == :run_started))
    end

    test "get_events/3 with wait_timeout_ms respects run_id filter", %{
      store: store,
      session: session
    } do
      {:ok, run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, run)
      {:ok, other_run} = Run.new(%{session_id: session.id})
      :ok = SessionStore.save_run(store, other_run)

      test_pid = self()

      reader_task =
        Task.async(fn ->
          send(test_pid, :reader_started)

          {:ok, events} =
            SessionStore.get_events(store, session.id,
              after: 0,
              run_id: run.id,
              wait_timeout_ms: 10_000
            )

          events
        end)

      assert_receive :reader_started, 1_000
      Process.sleep(50)

      # Append event for other run — should NOT unblock
      {:ok, other_event} =
        Event.new(%{type: :run_started, session_id: session.id, run_id: other_run.id})

      {:ok, _} = SessionStore.append_event_with_sequence(store, other_event)

      Process.sleep(100)

      # Append event for correct run — should unblock
      {:ok, event} = Event.new(%{type: :run_started, session_id: session.id, run_id: run.id})
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      events = Task.await(reader_task, 5_000)
      assert events != []
      assert Enum.all?(events, &(&1.run_id == run.id))
    end

    test "get_events/3 without wait_timeout_ms returns immediately", %{
      store: store,
      session: session
    } do
      start = System.monotonic_time(:millisecond)
      {:ok, events} = SessionStore.get_events(store, session.id, after: 0)
      elapsed = System.monotonic_time(:millisecond) - start

      assert events == []
      assert elapsed < 100
    end
  end

  describe "Idempotency guarantees" do
    test "duplicate session saves don't create duplicates" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})

      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.save_session(store, session)

      {:ok, sessions} = SessionStore.list_sessions(store)
      assert length(sessions) == 1
    end

    test "duplicate run saves don't create duplicates" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)
      {:ok, run} = Run.new(%{session_id: session.id})

      :ok = SessionStore.save_run(store, run)
      :ok = SessionStore.save_run(store, run)
      :ok = SessionStore.save_run(store, run)

      {:ok, runs} = SessionStore.list_runs(store, session.id)
      assert length(runs) == 1
    end

    test "events with same ID are deduplicated" do
      store = new_store()
      {:ok, session} = Session.new(%{agent_id: "agent-1"})
      :ok = SessionStore.save_session(store, session)
      {:ok, event} = Event.new(%{type: :session_created, session_id: session.id})

      :ok = SessionStore.append_event(store, event)
      :ok = SessionStore.append_event(store, event)
      :ok = SessionStore.append_event(store, event)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert length(events) == 1
    end
  end
end
