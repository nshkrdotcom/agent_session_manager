defmodule AgentSessionManager.Adapters.EctoSessionStoreTest do
  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.{Migration, MigrationV2}

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    ArtifactSchema,
    EventSchema,
    RunSchema,
    SessionSchema,
    SessionSequenceSchema
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.TestRepo

  import AgentSessionManager.Test.Fixtures

  @db_path Path.join(System.tmp_dir!(), "asm_ecto_test_shared.db")

  setup_all _ctx do
    # Clean up any leftover files
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, TestRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = TestRepo.start_link()
    Ecto.Migrator.up(TestRepo, 1, Migration, log: false)
    Ecto.Migrator.up(TestRepo, 2, MigrationV2, log: false)

    on_exit(fn ->
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
      catch
        :exit, _ -> :ok
      end

      File.rm(@db_path)
      File.rm(@db_path <> "-wal")
      File.rm(@db_path <> "-shm")
    end)

    :ok
  end

  setup _ctx do
    # Clear all data between tests using schema-based deletes for portability
    TestRepo.delete_all(ArtifactSchema)
    TestRepo.delete_all(EventSchema)
    TestRepo.delete_all(SessionSequenceSchema)
    TestRepo.delete_all(RunSchema)
    TestRepo.delete_all(SessionSchema)

    {:ok, store} = EctoSessionStore.start_link(repo: TestRepo)

    cleanup_on_exit(fn -> safe_stop(store) end)

    %{store: store}
  end

  # ============================================================================
  # Session Operations
  # ============================================================================

  describe "save_session/2" do
    test "saves a session successfully", %{store: store} do
      session = build_session(agent_id: "test-agent")
      assert :ok = SessionStore.save_session(store, session)
    end

    test "is idempotent - saves same session twice", %{store: store} do
      session = build_session(agent_id: "test-agent")
      assert :ok = SessionStore.save_session(store, session)
      assert :ok = SessionStore.save_session(store, session)
    end

    test "updates session on re-save with same ID", %{store: store} do
      session = build_session(agent_id: "test-agent")
      :ok = SessionStore.save_session(store, session)

      updated = %{session | status: :active}
      :ok = SessionStore.save_session(store, updated)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.status == :active
    end

    test "works through SessionStore port when using {EctoSessionStore, Repo} ref" do
      store_ref = {EctoSessionStore, TestRepo}
      session = build_session(index: 6100, agent_id: "module-ref-agent")

      assert :ok = SessionStore.save_session(store_ref, session)
      assert {:ok, fetched} = SessionStore.get_session(store_ref, session.id)
      assert fetched.id == session.id
      assert fetched.agent_id == "module-ref-agent"
    end
  end

  describe "get_session/2" do
    test "retrieves a saved session", %{store: store} do
      session = build_session(agent_id: "test-agent", tags: ["a", "b"])
      :ok = SessionStore.save_session(store, session)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.id == session.id
      assert retrieved.agent_id == "test-agent"
      assert retrieved.status == :pending
      assert retrieved.tags == ["a", "b"]
    end

    test "returns error for non-existent session", %{store: store} do
      {:error, %Error{code: :session_not_found}} =
        SessionStore.get_session(store, "ses_nonexistent")
    end

    test "preserves metadata and context", %{store: store} do
      session =
        build_session(
          metadata: %{user_id: "u123"},
          context: %{system_prompt: "hello"}
        )

      :ok = SessionStore.save_session(store, session)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.metadata == %{user_id: "u123"}
      assert retrieved.context == %{system_prompt: "hello"}
    end
  end

  describe "list_sessions/2" do
    test "lists all sessions", %{store: store} do
      s1 = build_session(index: 1, agent_id: "agent-1")
      s2 = build_session(index: 2, agent_id: "agent-2")
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)

      {:ok, sessions} = SessionStore.list_sessions(store)
      assert length(sessions) == 2
    end

    test "filters by status", %{store: store} do
      s1 = build_session(index: 1, status: :pending)
      s2 = build_session(index: 2, status: :active)
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)

      {:ok, pending} = SessionStore.list_sessions(store, status: :pending)
      assert length(pending) == 1
      assert hd(pending).id == s1.id
    end

    test "filters by agent_id", %{store: store} do
      s1 = build_session(index: 1, agent_id: "agent-1")
      s2 = build_session(index: 2, agent_id: "agent-2")
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)

      {:ok, filtered} = SessionStore.list_sessions(store, agent_id: "agent-1")
      assert length(filtered) == 1
      assert hd(filtered).agent_id == "agent-1"
    end

    test "applies limit", %{store: store} do
      for i <- 1..5 do
        :ok = SessionStore.save_session(store, build_session(index: i))
      end

      {:ok, limited} = SessionStore.list_sessions(store, limit: 3)
      assert length(limited) == 3
    end

    test "returns empty list when no sessions", %{store: store} do
      {:ok, []} = SessionStore.list_sessions(store)
    end
  end

  describe "delete_session/2" do
    test "deletes existing session", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.delete_session(store, session.id)

      {:error, %Error{code: :session_not_found}} =
        SessionStore.get_session(store, session.id)
    end

    test "is idempotent - deleting non-existent session returns :ok", %{store: store} do
      :ok = SessionStore.delete_session(store, "ses_nonexistent")
    end

    test "deletes related runs, events, artifacts, and sequence counters", %{store: store} do
      session = build_session(index: 1100)
      :ok = SessionStore.save_session(store, session)

      run = build_run(index: 1101, session_id: session.id, status: :completed)
      :ok = SessionStore.save_run(store, run)

      event = build_event(index: 1102, session_id: session.id, run_id: run.id, type: :run_started)
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      TestRepo.insert!(%ArtifactSchema{
        id: "art_1100",
        session_id: session.id,
        run_id: run.id,
        key: "artifact/#{session.id}",
        content_type: "text/plain",
        byte_size: 42,
        checksum_sha256: String.duplicate("a", 64),
        storage_backend: "file",
        storage_ref: "file:///tmp/artifact_1100",
        metadata: %{},
        created_at: now
      })

      assert :ok = SessionStore.delete_session(store, session.id)

      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, session.id)

      assert TestRepo.aggregate(RunSchema, :count, :id) == 0
      assert TestRepo.aggregate(EventSchema, :count, :id) == 0
      assert TestRepo.aggregate(SessionSequenceSchema, :count, :session_id) == 0
      assert TestRepo.aggregate(ArtifactSchema, :count, :id) == 0
    end
  end

  # ============================================================================
  # Run Operations
  # ============================================================================

  describe "save_run/2" do
    test "saves a run successfully", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id)
      assert :ok = SessionStore.save_run(store, run)
    end

    test "is idempotent", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id)
      :ok = SessionStore.save_run(store, run)
      :ok = SessionStore.save_run(store, run)
    end

    test "updates run on re-save", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id)
      :ok = SessionStore.save_run(store, run)

      updated = %{run | status: :running}
      :ok = SessionStore.save_run(store, updated)

      {:ok, retrieved} = SessionStore.get_run(store, run.id)
      assert retrieved.status == :running
    end
  end

  describe "get_run/2" do
    test "retrieves a saved run", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id, input: %{prompt: "hello"})
      :ok = SessionStore.save_run(store, run)

      {:ok, retrieved} = SessionStore.get_run(store, run.id)
      assert retrieved.id == run.id
      assert retrieved.session_id == session.id
      assert retrieved.input == %{prompt: "hello"}
    end

    test "returns error for non-existent run", %{store: store} do
      {:error, %Error{code: :run_not_found}} =
        SessionStore.get_run(store, "run_nonexistent")
    end

    test "preserves token usage and metadata", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run =
        build_run(
          session_id: session.id,
          token_usage: %{input_tokens: 100, output_tokens: 50},
          metadata: %{provider: "claude"}
        )

      :ok = SessionStore.save_run(store, run)

      {:ok, retrieved} = SessionStore.get_run(store, run.id)
      assert retrieved.token_usage == %{input_tokens: 100, output_tokens: 50}
      assert retrieved.metadata == %{provider: "claude"}
    end
  end

  describe "list_runs/3" do
    test "lists all runs for a session", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      r1 = build_run(index: 1, session_id: session.id)
      r2 = build_run(index: 2, session_id: session.id)
      :ok = SessionStore.save_run(store, r1)
      :ok = SessionStore.save_run(store, r2)

      {:ok, runs} = SessionStore.list_runs(store, session.id)
      assert length(runs) == 2
    end

    test "filters by status", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      r1 = build_run(index: 1, session_id: session.id, status: :pending)
      r2 = build_run(index: 2, session_id: session.id, status: :running)
      :ok = SessionStore.save_run(store, r1)
      :ok = SessionStore.save_run(store, r2)

      {:ok, running} = SessionStore.list_runs(store, session.id, status: :running)
      assert length(running) == 1
      assert hd(running).id == r2.id
    end

    test "only returns runs for the specified session", %{store: store} do
      s1 = build_session(index: 1)
      s2 = build_session(index: 2)
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)

      r1 = build_run(index: 1, session_id: s1.id)
      r2 = build_run(index: 2, session_id: s2.id)
      :ok = SessionStore.save_run(store, r1)
      :ok = SessionStore.save_run(store, r2)

      {:ok, runs} = SessionStore.list_runs(store, s1.id)
      assert length(runs) == 1
      assert hd(runs).session_id == s1.id
    end

    test "returns empty list when no runs", %{store: store} do
      {:ok, []} = SessionStore.list_runs(store, "ses_empty")
    end
  end

  describe "get_active_run/2" do
    test "returns the active (running) run", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id, status: :running)
      :ok = SessionStore.save_run(store, run)

      {:ok, active} = SessionStore.get_active_run(store, session.id)
      assert active.id == run.id
      assert active.status == :running
    end

    test "returns nil when no active run", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      {:ok, nil} = SessionStore.get_active_run(store, session.id)
    end

    test "returns nil when all runs are completed", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id, status: :completed)
      :ok = SessionStore.save_run(store, run)

      {:ok, nil} = SessionStore.get_active_run(store, session.id)
    end
  end

  # ============================================================================
  # Event Operations
  # ============================================================================

  describe "append_event/2" do
    test "appends event successfully", %{store: store} do
      event = build_event(type: :session_created)
      assert :ok = SessionStore.append_event(store, event)
    end

    test "is idempotent - same event ID appended twice", %{store: store} do
      event = build_event(type: :session_created)
      :ok = SessionStore.append_event(store, event)
      :ok = SessionStore.append_event(store, event)

      {:ok, events} = SessionStore.get_events(store, event.session_id)
      assert length(events) == 1
    end
  end

  describe "append_event_with_sequence/2" do
    test "assigns monotonically increasing sequence numbers", %{store: store} do
      e1 = build_event(index: 1, type: :run_started)
      e2 = build_event(index: 2, type: :message_received)
      e3 = build_event(index: 3, type: :run_completed)

      {:ok, stored1} = SessionStore.append_event_with_sequence(store, e1)
      {:ok, stored2} = SessionStore.append_event_with_sequence(store, e2)
      {:ok, stored3} = SessionStore.append_event_with_sequence(store, e3)

      assert stored1.sequence_number == 1
      assert stored2.sequence_number == 2
      assert stored3.sequence_number == 3
    end

    test "is idempotent - returns original event on duplicate", %{store: store} do
      event = build_event(type: :session_created)

      {:ok, first} = SessionStore.append_event_with_sequence(store, event)
      {:ok, second} = SessionStore.append_event_with_sequence(store, event)

      assert first.sequence_number == second.sequence_number
      assert first.id == second.id
    end

    test "sequences are per-session", %{store: store} do
      s1_event = build_event(index: 1, session_id: "ses_1", type: :session_created)
      s2_event = build_event(index: 2, session_id: "ses_2", type: :session_created)

      {:ok, stored1} = SessionStore.append_event_with_sequence(store, s1_event)
      {:ok, stored2} = SessionStore.append_event_with_sequence(store, s2_event)

      assert stored1.sequence_number == 1
      assert stored2.sequence_number == 1
    end

    test "returns error for invalid event and keeps store alive", %{store: store} do
      invalid_event = build_event(index: 1200, timestamp: nil)

      assert {:error, %Error{code: :validation_error}} =
               SessionStore.append_event_with_sequence(store, invalid_event)

      assert Process.alive?(store)

      valid_event =
        build_event(
          index: 1201,
          session_id: invalid_event.session_id,
          type: :session_created
        )

      assert {:ok, _stored} = SessionStore.append_event_with_sequence(store, valid_event)
    end
  end

  describe "append_events/2" do
    test "assigns contiguous sequence numbers in a batch", %{store: store} do
      e1 = build_event(index: 1, type: :run_started)
      e2 = build_event(index: 2, session_id: e1.session_id, type: :message_received)
      e3 = build_event(index: 3, session_id: e1.session_id, type: :run_completed)

      {:ok, [stored1, stored2, stored3]} = SessionStore.append_events(store, [e1, e2, e3])

      assert stored1.sequence_number == 1
      assert stored2.sequence_number == 2
      assert stored3.sequence_number == 3
      assert {:ok, 3} = SessionStore.get_latest_sequence(store, e1.session_id)
    end

    test "is idempotent for duplicate IDs in a batch", %{store: store} do
      event = build_event(type: :session_created)

      {:ok, [first, second]} = SessionStore.append_events(store, [event, event])

      assert first.id == second.id
      assert first.sequence_number == second.sequence_number

      {:ok, events} = SessionStore.get_events(store, event.session_id)
      assert length(events) == 1
    end

    test "handles large SQLite batches by chunking insert_all calls", %{store: store} do
      session_id = "ses_large_batch"
      run_id = "run_large_batch"
      event_count = 3_000

      events =
        for index <- 1..event_count do
          build_event(
            index: 20_000 + index,
            session_id: session_id,
            run_id: run_id,
            type: :message_received,
            data: %{index: index}
          )
        end

      assert {:ok, stored_events} = SessionStore.append_events(store, events)
      assert length(stored_events) == event_count
      assert hd(stored_events).sequence_number == 1
      assert List.last(stored_events).sequence_number == event_count
      assert {:ok, ^event_count} = SessionStore.get_latest_sequence(store, session_id)
    end
  end

  describe "get_events/3" do
    setup %{store: store} do
      session_id = "ses_events"
      run_id = "run_events"

      events = [
        build_event(index: 1, session_id: session_id, run_id: run_id, type: :run_started),
        build_event(index: 2, session_id: session_id, run_id: run_id, type: :message_received),
        build_event(index: 3, session_id: session_id, run_id: run_id, type: :message_streamed),
        build_event(index: 4, session_id: session_id, run_id: run_id, type: :run_completed)
      ]

      for event <- events do
        {:ok, _} = SessionStore.append_event_with_sequence(store, event)
      end

      %{session_id: session_id, run_id: run_id}
    end

    test "returns all events for a session", %{store: store, session_id: sid} do
      {:ok, events} = SessionStore.get_events(store, sid)
      assert length(events) == 4
    end

    test "returns events in append order", %{store: store, session_id: sid} do
      {:ok, events} = SessionStore.get_events(store, sid)
      assert Enum.at(events, 0).type == :run_started
      assert Enum.at(events, 1).type == :message_received
      assert Enum.at(events, 2).type == :message_streamed
      assert Enum.at(events, 3).type == :run_completed
    end

    test "filters by run_id", %{store: store, session_id: sid} do
      other = build_event(index: 10, session_id: sid, run_id: "run_other", type: :run_started)
      {:ok, _} = SessionStore.append_event_with_sequence(store, other)

      {:ok, filtered} = SessionStore.get_events(store, sid, run_id: "run_events")
      assert length(filtered) == 4
    end

    test "filters by type", %{store: store, session_id: sid} do
      {:ok, filtered} = SessionStore.get_events(store, sid, type: :message_received)
      assert length(filtered) == 1
      assert hd(filtered).type == :message_received
    end

    test "filters by :after cursor", %{store: store, session_id: sid} do
      {:ok, filtered} = SessionStore.get_events(store, sid, after: 2)
      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.sequence_number > 2))
    end

    test "filters by :before cursor", %{store: store, session_id: sid} do
      {:ok, filtered} = SessionStore.get_events(store, sid, before: 3)
      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.sequence_number < 3))
    end

    test "filters by :since timestamp", %{store: store, session_id: sid} do
      base_time = DateTime.utc_now()

      older =
        build_event(
          index: 20,
          session_id: sid,
          run_id: "run_events",
          type: :message_received,
          timestamp: DateTime.add(base_time, -60, :second)
        )

      newer =
        build_event(
          index: 21,
          session_id: sid,
          run_id: "run_events",
          type: :message_received,
          timestamp: DateTime.add(base_time, 60, :second)
        )

      {:ok, _} = SessionStore.append_event_with_sequence(store, older)
      {:ok, _} = SessionStore.append_event_with_sequence(store, newer)

      {:ok, filtered} = SessionStore.get_events(store, sid, since: base_time)
      assert length(filtered) == 1
      assert hd(filtered).id == newer.id
    end

    test "applies limit", %{store: store, session_id: sid} do
      {:ok, filtered} = SessionStore.get_events(store, sid, limit: 2)
      assert length(filtered) == 2
    end

    test "returns empty list for non-existent session", %{store: store} do
      {:ok, []} = SessionStore.get_events(store, "ses_nonexistent")
    end

    test "combines filters", %{store: store, session_id: sid} do
      {:ok, filtered} =
        SessionStore.get_events(store, sid, after: 1, before: 4, limit: 1)

      assert length(filtered) == 1
      assert hd(filtered).sequence_number == 2
    end
  end

  describe "get_latest_sequence/2" do
    test "returns 0 when no events exist", %{store: store} do
      {:ok, 0} = SessionStore.get_latest_sequence(store, "ses_empty")
    end

    test "returns latest sequence after appending events", %{store: store} do
      e1 = build_event(index: 1, type: :run_started)
      e2 = build_event(index: 2, type: :message_received)

      {:ok, _} = SessionStore.append_event_with_sequence(store, e1)
      {:ok, _} = SessionStore.append_event_with_sequence(store, e2)

      {:ok, latest} = SessionStore.get_latest_sequence(store, e1.session_id)
      assert latest == 2
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "data roundtrip fidelity" do
    test "session roundtrip keeps unknown JSON keys as strings", %{store: store} do
      unique_key = "unknown_key_#{System.unique_integer([:positive, :monotonic])}"
      nested_key = "nested_key_#{System.unique_integer([:positive, :monotonic])}"

      session =
        build_session(
          metadata: %{unique_key => %{nested_key => "metadata_value"}},
          context: %{unique_key => %{nested_key => "context_value"}}
        )

      :ok = SessionStore.save_session(store, session)
      {:ok, retrieved} = SessionStore.get_session(store, session.id)

      assert retrieved.metadata == %{unique_key => %{nested_key => "metadata_value"}}
      assert retrieved.context == %{unique_key => %{nested_key => "context_value"}}
    end

    test "session roundtrips preserve all fields", %{store: store} do
      session =
        build_session(
          agent_id: "test-agent",
          status: :active,
          parent_session_id: "ses_parent",
          metadata: %{key: "value", nested: %{a: 1}},
          context: %{system_prompt: "You are helpful"},
          tags: ["tag1", "tag2"]
        )

      :ok = SessionStore.save_session(store, session)
      {:ok, retrieved} = SessionStore.get_session(store, session.id)

      assert retrieved.agent_id == session.agent_id
      assert retrieved.status == session.status
      assert retrieved.parent_session_id == session.parent_session_id
      assert retrieved.metadata == session.metadata
      assert retrieved.context == session.context
      assert retrieved.tags == session.tags
    end

    test "run roundtrips preserve all fields", %{store: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run =
        build_run(
          session_id: session.id,
          status: :completed,
          input: %{messages: [%{role: "user", content: "hi"}]},
          output: %{content: "hello", stop_reason: "end_turn"},
          error: nil,
          metadata: %{provider: "claude"},
          turn_count: 3,
          token_usage: %{input_tokens: 10, output_tokens: 20}
        )

      :ok = SessionStore.save_run(store, run)
      {:ok, retrieved} = SessionStore.get_run(store, run.id)

      assert retrieved.input == run.input
      assert retrieved.output == run.output
      assert retrieved.metadata == run.metadata
      assert retrieved.turn_count == run.turn_count
      assert retrieved.token_usage == run.token_usage
    end

    test "event roundtrips preserve all fields", %{store: store} do
      event =
        build_event(
          type: :message_received,
          run_id: "run_1",
          data: %{content: "Hello!", role: "assistant"},
          metadata: %{provider: "claude", model: "test"}
        )

      {:ok, stored} = SessionStore.append_event_with_sequence(store, event)

      {:ok, [retrieved]} = SessionStore.get_events(store, event.session_id)

      assert retrieved.id == event.id
      assert retrieved.type == :message_received
      assert retrieved.run_id == "run_1"
      assert retrieved.data == %{content: "Hello!", role: "assistant"}
      assert retrieved.metadata == %{provider: "claude", model: "test"}
      assert retrieved.sequence_number == stored.sequence_number
    end
  end

  describe "flush/2" do
    test "persists session, run, and events in one call", %{store: store} do
      session = build_session(index: 900, agent_id: "flush-agent")
      run = build_run(index: 901, session_id: session.id, status: :completed)
      event = build_event(index: 902, session_id: session.id, run_id: run.id, type: :run_started)

      assert :ok =
               SessionStore.flush(store, %{
                 session: session,
                 run: run,
                 events: [event],
                 provider_metadata: %{}
               })

      assert {:ok, _} = SessionStore.get_session(store, session.id)
      assert {:ok, _} = SessionStore.get_run(store, run.id)
      assert {:ok, [stored_event]} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert stored_event.type == :run_started
    end

    test "rolls back session and run when event payload is invalid", %{store: store} do
      session = build_session(index: 990, agent_id: "flush-agent")
      run = build_run(index: 991, session_id: session.id, status: :completed)

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
end
