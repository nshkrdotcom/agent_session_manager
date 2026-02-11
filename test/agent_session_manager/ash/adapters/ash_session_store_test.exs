if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshSessionStoreTest do
    use ExUnit.Case, async: false
    @moduletag :ash

    alias AgentSessionManager.Ash.Adapters.AshSessionStore
    alias AgentSessionManager.Ash.Resources
    alias AgentSessionManager.Core.Error
    alias AgentSessionManager.Ports.SessionStore
    import AgentSessionManager.Test.Fixtures
    alias AgentSessionManager.Ash.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    setup do
      :ok = Sandbox.checkout(TestRepo)
      store = {AshSessionStore, AgentSessionManager.Ash.TestDomain}
      {:ok, store: store}
    end

    test "save_session/get_session upserts and retrieves sessions", %{store: store} do
      session = build_session(id: "ash_s_1", agent_id: "agent-a")
      assert :ok = SessionStore.save_session(store, session)
      assert {:ok, got} = SessionStore.get_session(store, session.id)
      assert got.id == session.id
      assert got.status == :pending

      updated = %{session | status: :active, metadata: %{step: 2}}
      assert :ok = SessionStore.save_session(store, updated)
      assert {:ok, got2} = SessionStore.get_session(store, session.id)
      assert got2.status == :active
      assert got2.metadata == %{step: 2}
    end

    test "get_session returns not_found error", %{store: store} do
      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, "missing_session")
    end

    test "list_sessions supports status/agent_id/limit filters", %{store: store} do
      s1 = build_session(id: "ash_ls_1", agent_id: "agent-a", status: :pending)
      s2 = build_session(id: "ash_ls_2", agent_id: "agent-a", status: :active)
      s3 = build_session(id: "ash_ls_3", agent_id: "agent-b", status: :active)
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)
      :ok = SessionStore.save_session(store, s3)

      assert {:ok, active} = SessionStore.list_sessions(store, status: :active)
      assert Enum.map(active, & &1.id) |> Enum.sort() == ["ash_ls_2", "ash_ls_3"]

      assert {:ok, agent_a} = SessionStore.list_sessions(store, agent_id: "agent-a")
      assert Enum.map(agent_a, & &1.id) |> Enum.sort() == ["ash_ls_1", "ash_ls_2"]

      assert {:ok, limited} = SessionStore.list_sessions(store, limit: 2)
      assert length(limited) == 2
    end

    test "delete_session is idempotent and cascades dependent rows", %{store: store} do
      now = DateTime.utc_now()
      session = build_session(id: "ash_del_1")
      :ok = SessionStore.save_session(store, session)
      run = build_run(id: "ash_del_run_1", session_id: session.id, status: :running)
      assert :ok = SessionStore.save_run(store, run)

      event =
        build_event(
          id: "ash_del_evt_1",
          type: :run_started,
          session_id: session.id,
          run_id: run.id
        )

      assert {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      Ash.create!(
        Resources.Artifact,
        %{
          id: "ash_art_1",
          session_id: session.id,
          run_id: run.id,
          key: "artifacts/#{session.id}/1",
          content_type: "application/json",
          byte_size: 16,
          checksum_sha256: String.duplicate("a", 64),
          storage_backend: "s3",
          storage_ref: "s3://bucket/key",
          metadata: %{},
          created_at: now
        },
        action: :create,
        domain: AgentSessionManager.Ash.TestDomain
      )

      assert {:ok, 1} = SessionStore.get_latest_sequence(store, session.id)
      assert :ok = SessionStore.delete_session(store, session.id)
      assert :ok = SessionStore.delete_session(store, session.id)

      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, session.id)

      assert {:error, %Error{code: :run_not_found}} = SessionStore.get_run(store, run.id)
      assert {:ok, []} = SessionStore.get_events(store, session.id)
      assert {:ok, 0} = SessionStore.get_latest_sequence(store, session.id)
    end

    test "save_run/get_run/list_runs upserts and filters runs", %{store: store} do
      session = build_session(id: "ash_runs_1")
      :ok = SessionStore.save_session(store, session)

      run1 = build_run(id: "ash_run_1", session_id: session.id, status: :pending)
      run2 = build_run(id: "ash_run_2", session_id: session.id, status: :running)
      :ok = SessionStore.save_run(store, run1)
      :ok = SessionStore.save_run(store, run2)

      updated_run1 = %{run1 | status: :completed}
      :ok = SessionStore.save_run(store, updated_run1)

      assert {:ok, got} = SessionStore.get_run(store, run1.id)
      assert got.status == :completed

      assert {:ok, all_runs} = SessionStore.list_runs(store, session.id)
      assert Enum.map(all_runs, & &1.id) |> Enum.sort() == ["ash_run_1", "ash_run_2"]

      assert {:ok, running_only} = SessionStore.list_runs(store, session.id, status: :running)
      assert Enum.map(running_only, & &1.id) == ["ash_run_2"]

      assert {:ok, limited} = SessionStore.list_runs(store, session.id, limit: 1)
      assert length(limited) == 1
    end

    test "get_run returns not_found error", %{store: store} do
      assert {:error, %Error{code: :run_not_found}} = SessionStore.get_run(store, "missing_run")
    end

    test "get_active_run returns running run or nil", %{store: store} do
      session = build_session(id: "ash_active_1")
      :ok = SessionStore.save_session(store, session)

      run_pending =
        build_run(id: "ash_active_run_pending", session_id: session.id, status: :pending)

      run_running =
        build_run(id: "ash_active_run_running", session_id: session.id, status: :running)

      :ok = SessionStore.save_run(store, run_pending)
      :ok = SessionStore.save_run(store, run_running)

      assert {:ok, active} = SessionStore.get_active_run(store, session.id)
      assert active.id == run_running.id

      :ok = SessionStore.save_run(store, %{run_running | status: :completed})
      assert {:ok, nil} = SessionStore.get_active_run(store, session.id)
    end

    test "append_event/2 stores idempotently", %{store: store} do
      session = build_session(id: "ash_s_4")
      :ok = SessionStore.save_session(store, session)

      e1 = build_event(id: "ash_e_4", type: :session_created, session_id: session.id)
      assert :ok = SessionStore.append_event(store, e1)
      assert :ok = SessionStore.append_event(store, e1)
      assert {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.count(events, &(&1.id == e1.id)) == 1
    end

    test "append_event_with_sequence assigns increasing sequence and is idempotent", %{
      store: store
    } do
      session = build_session(id: "ash_seq_1")
      :ok = SessionStore.save_session(store, session)

      e1 = build_event(id: "ash_seq_evt_1", type: :session_created, session_id: session.id)
      e2 = build_event(id: "ash_seq_evt_2", type: :session_started, session_id: session.id)

      assert {:ok, s1} = SessionStore.append_event_with_sequence(store, e1)
      assert {:ok, s2} = SessionStore.append_event_with_sequence(store, e2)
      assert s1.sequence_number == 1
      assert s2.sequence_number == 2

      assert {:ok, dup} = SessionStore.append_event_with_sequence(store, e1)
      assert dup.id == s1.id
      assert dup.sequence_number == s1.sequence_number
    end

    test "append_events assigns contiguous sequences and preserves input order", %{store: store} do
      s1 = build_session(id: "ash_batch_1")
      s2 = build_session(id: "ash_batch_2")
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)

      events = [
        build_event(id: "ash_b_1", type: :session_created, session_id: s1.id),
        build_event(id: "ash_b_2", type: :session_started, session_id: s1.id),
        build_event(id: "ash_b_3", type: :session_created, session_id: s2.id),
        build_event(id: "ash_b_4", type: :session_started, session_id: s2.id)
      ]

      assert {:ok, stored} = SessionStore.append_events(store, events)
      assert Enum.map(stored, & &1.id) == Enum.map(events, & &1.id)

      s1_seqs =
        stored
        |> Enum.filter(&(&1.session_id == s1.id))
        |> Enum.map(& &1.sequence_number)

      s2_seqs =
        stored
        |> Enum.filter(&(&1.session_id == s2.id))
        |> Enum.map(& &1.sequence_number)

      assert s1_seqs == [1, 2]
      assert s2_seqs == [1, 2]

      assert {:ok, deduped} = SessionStore.append_events(store, [hd(events), hd(events)])
      assert length(deduped) == 2
      assert Enum.at(deduped, 0).sequence_number == Enum.at(deduped, 1).sequence_number
    end

    test "flush persists session run events atomically", %{store: store} do
      session = build_session(id: "ash_s_5")
      run = build_run(id: "ash_r_5", session_id: session.id)
      e1 = build_event(id: "ash_e_5", type: :run_started, session_id: session.id, run_id: run.id)

      payload = %{session: session, run: run, events: [e1], provider_metadata: %{}}
      assert :ok = SessionStore.flush(store, payload)

      assert {:ok, _} = SessionStore.get_session(store, session.id)
      assert {:ok, _} = SessionStore.get_run(store, run.id)
      assert {:ok, [stored]} = SessionStore.get_events(store, session.id)
      assert stored.id == e1.id
    end

    test "flush rolls back when events are invalid", %{store: store} do
      session = build_session(id: "ash_flush_rollback_session")
      run = build_run(id: "ash_flush_rollback_run", session_id: session.id)

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

    test "get_events supports run_id/type/since/after/before/limit filters", %{store: store} do
      session = build_session(id: "ash_ev_filter_s")
      run1 = build_run(id: "ash_ev_filter_r1", session_id: session.id)
      run2 = build_run(id: "ash_ev_filter_r2", session_id: session.id)
      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.save_run(store, run1)
      :ok = SessionStore.save_run(store, run2)

      base = ~U[2026-02-10 00:00:00.000000Z]

      e1 =
        build_event(
          id: "ash_ev_filter_1",
          type: :run_started,
          session_id: session.id,
          run_id: run1.id,
          timestamp: DateTime.add(base, 1, :second)
        )

      e2 =
        build_event(
          id: "ash_ev_filter_2",
          type: :message_received,
          session_id: session.id,
          run_id: run1.id,
          timestamp: DateTime.add(base, 2, :second)
        )

      e3 =
        build_event(
          id: "ash_ev_filter_3",
          type: :message_received,
          session_id: session.id,
          run_id: run2.id,
          timestamp: DateTime.add(base, 3, :second)
        )

      {:ok, [s1, s2, s3]} = SessionStore.append_events(store, [e1, e2, e3])

      assert {:ok, by_run} = SessionStore.get_events(store, session.id, run_id: run1.id)
      assert Enum.map(by_run, & &1.id) == [s1.id, s2.id]

      assert {:ok, by_type} = SessionStore.get_events(store, session.id, type: :message_received)
      assert Enum.map(by_type, & &1.id) == [s2.id, s3.id]

      assert {:ok, by_since} =
               SessionStore.get_events(
                 store,
                 session.id,
                 since: DateTime.add(base, 2, :second)
               )

      assert Enum.map(by_since, & &1.id) == [s3.id]

      assert {:ok, after_seq} =
               SessionStore.get_events(store, session.id, after: s1.sequence_number)

      assert Enum.map(after_seq, & &1.sequence_number) == [2, 3]

      assert {:ok, before_seq} =
               SessionStore.get_events(store, session.id, before: s3.sequence_number)

      assert Enum.map(before_seq, & &1.sequence_number) == [1, 2]

      assert {:ok, limited} = SessionStore.get_events(store, session.id, limit: 2)
      assert length(limited) == 2
    end

    test "get_latest_sequence returns 0 for empty sessions and latest value after appends", %{
      store: store
    } do
      session = build_session(id: "ash_seq_latest_1")
      :ok = SessionStore.save_session(store, session)

      assert {:ok, 0} = SessionStore.get_latest_sequence(store, session.id)

      e1 = build_event(id: "ash_seq_latest_evt_1", type: :session_created, session_id: session.id)
      e2 = build_event(id: "ash_seq_latest_evt_2", type: :session_started, session_id: session.id)
      {:ok, _} = SessionStore.append_events(store, [e1, e2])

      assert {:ok, 2} = SessionStore.get_latest_sequence(store, session.id)
    end
  end
end
