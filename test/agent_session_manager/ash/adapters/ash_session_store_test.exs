if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshSessionStoreTest do
    use ExUnit.Case, async: false
    @moduletag :ash

    alias AgentSessionManager.Ash.Adapters.AshSessionStore
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

    test "save/get/list/delete session", %{store: store} do
      session = build_session(id: "ash_s_1", agent_id: "agent-a")
      assert :ok = SessionStore.save_session(store, session)
      assert {:ok, got} = SessionStore.get_session(store, session.id)
      assert got.id == session.id
      assert {:ok, sessions} = SessionStore.list_sessions(store, agent_id: "agent-a")
      assert Enum.any?(sessions, &(&1.id == session.id))
      assert :ok = SessionStore.delete_session(store, session.id)

      assert {:error, %Error{code: :session_not_found}} =
               SessionStore.get_session(store, session.id)
    end

    test "save/get/list run and active run", %{store: store} do
      session = build_session(id: "ash_s_2")
      :ok = SessionStore.save_session(store, session)
      run = build_run(id: "ash_r_1", session_id: session.id, status: :running)
      assert :ok = SessionStore.save_run(store, run)
      assert {:ok, got} = SessionStore.get_run(store, run.id)
      assert got.id == run.id
      assert {:ok, runs} = SessionStore.list_runs(store, session.id)
      assert Enum.any?(runs, &(&1.id == run.id))
      assert {:ok, active} = SessionStore.get_active_run(store, session.id)
      assert active.id == run.id
    end

    test "append_event_with_sequence, append_events, get_events, latest sequence", %{store: store} do
      session = build_session(id: "ash_s_3")
      :ok = SessionStore.save_session(store, session)
      run = build_run(id: "ash_r_3", session_id: session.id)
      :ok = SessionStore.save_run(store, run)

      e1 =
        build_event(id: "ash_e_1", type: :session_created, session_id: session.id, run_id: run.id)

      e2 = build_event(id: "ash_e_2", type: :run_started, session_id: session.id, run_id: run.id)

      assert {:ok, se1} = SessionStore.append_event_with_sequence(store, e1)
      assert se1.sequence_number == 1

      assert {:ok, [b1, b2]} = SessionStore.append_events(store, [e1, e2])
      assert b1.id == e1.id
      assert b2.sequence_number >= 2

      assert {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert length(events) >= 2

      assert {:ok, seq} = SessionStore.get_latest_sequence(store, session.id)
      assert seq >= 2
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
  end
end
