if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshQueryAPITest do
    use ExUnit.Case, async: false

    alias AgentSessionManager.Ash.Adapters.{AshQueryAPI, AshSessionStore}
    alias AgentSessionManager.Ports.{QueryAPI, SessionStore}
    import AgentSessionManager.Test.Fixtures

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(AgentSessionManager.Ash.TestRepo)
      store = {AshSessionStore, AgentSessionManager.Ash.TestDomain}
      query = {AshQueryAPI, AgentSessionManager.Ash.TestDomain}

      session = build_session(id: "q_s_1", agent_id: "agent-q", status: :completed)

      run =
        build_run(
          id: "q_r_1",
          session_id: session.id,
          status: :completed,
          provider: "claude",
          token_usage: %{input_tokens: 3, output_tokens: 4, total_tokens: 7}
        )

      e1 = build_event(id: "q_e_1", session_id: session.id, run_id: run.id, type: :run_started)
      e2 = build_event(id: "q_e_2", session_id: session.id, run_id: run.id, type: :run_completed)

      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.save_run(store, run)
      {:ok, _} = SessionStore.append_events(store, [e1, e2])

      {:ok, query: query, session: session, run: run}
    end

    test "search_sessions", %{query: query, session: session} do
      assert {:ok, %{sessions: sessions, total_count: count}} =
               QueryAPI.search_sessions(query, agent_id: "agent-q")

      assert count >= 1
      assert Enum.any?(sessions, &(&1.id == session.id))
    end

    test "get_session_stats", %{query: query, session: session} do
      assert {:ok, stats} = QueryAPI.get_session_stats(query, session.id)
      assert stats.event_count >= 2
      assert stats.run_count >= 1
    end

    test "search_runs and usage summary", %{query: query, run: run} do
      assert {:ok, %{runs: runs}} = QueryAPI.search_runs(query, provider: "claude")
      assert Enum.any?(runs, &(&1.id == run.id))

      assert {:ok, summary} = QueryAPI.get_usage_summary(query, provider: "claude")
      assert summary.total_tokens >= 7
    end

    test "search_events and count_events", %{query: query, session: session} do
      assert {:ok, %{events: events}} =
               QueryAPI.search_events(query,
                 session_ids: [session.id],
                 types: [:run_started, :run_completed]
               )

      assert length(events) >= 2

      assert {:ok, count} = QueryAPI.count_events(query, session_ids: [session.id])
      assert count >= 2
    end

    test "export_session", %{query: query, session: session} do
      assert {:ok, export} = QueryAPI.export_session(query, session.id)
      assert export.session.id == session.id
      assert length(export.runs) >= 1
      assert length(export.events) >= 2
    end
  end
end
