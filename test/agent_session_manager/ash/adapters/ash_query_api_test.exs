if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshQueryAPITest do
    use ExUnit.Case, async: false
    @moduletag :ash

    alias AgentSessionManager.Ash.Adapters.{AshQueryAPI, AshSessionStore}
    alias AgentSessionManager.Ash.Resources
    alias AgentSessionManager.Core.Error
    alias AgentSessionManager.Ports.{QueryAPI, SessionStore}
    import AgentSessionManager.Test.Fixtures
    alias AgentSessionManager.Ash.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    setup do
      :ok = Sandbox.checkout(TestRepo)
      store = {AshSessionStore, AgentSessionManager.Ash.TestDomain}
      query = {AshQueryAPI, AgentSessionManager.Ash.TestDomain}

      {:ok, store: store, query: query}
    end

    defp seed_session_with_runs_and_events(store) do
      base = ~U[2026-02-10 00:00:00.000000Z]

      session_1 =
        build_session(
          id: "q_s_1",
          agent_id: "agent-q",
          status: :completed,
          created_at: DateTime.add(base, 10, :second),
          updated_at: DateTime.add(base, 15, :second),
          tags: ["priority"]
        )

      session_2 =
        build_session(
          id: "q_s_2",
          agent_id: "agent-r",
          status: :active,
          created_at: DateTime.add(base, 20, :second),
          updated_at: DateTime.add(base, 25, :second)
        )

      session_3 =
        build_session(
          id: "q_s_3",
          agent_id: "agent-z",
          status: :completed,
          created_at: DateTime.add(base, 30, :second),
          updated_at: DateTime.add(base, 35, :second),
          deleted_at: DateTime.add(base, 40, :second)
        )

      run_1 =
        build_run(
          id: "q_r_1",
          session_id: session_1.id,
          status: :completed,
          provider: "claude",
          started_at: DateTime.add(base, 11, :second),
          token_usage: %{input_tokens: 3, output_tokens: 4, total_tokens: 7}
        )

      run_2 =
        build_run(
          id: "q_r_2",
          session_id: session_1.id,
          status: :failed,
          provider: "codex",
          started_at: DateTime.add(base, 12, :second),
          token_usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
        )

      run_3 =
        build_run(
          id: "q_r_3",
          session_id: session_2.id,
          status: :running,
          provider: "claude",
          started_at: DateTime.add(base, 30, :second),
          token_usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
        )

      :ok = SessionStore.save_session(store, session_1)
      :ok = SessionStore.save_session(store, session_2)
      :ok = SessionStore.save_session(store, session_3)
      :ok = SessionStore.save_run(store, run_1)
      :ok = SessionStore.save_run(store, run_2)
      :ok = SessionStore.save_run(store, run_3)

      e1 =
        build_event(
          id: "q_e_1",
          session_id: session_1.id,
          run_id: run_1.id,
          type: :run_started,
          timestamp: DateTime.add(base, 11, :second),
          correlation_id: "corr-1",
          provider: "claude"
        )

      e2 =
        build_event(
          id: "q_e_2",
          session_id: session_1.id,
          run_id: run_1.id,
          type: :run_completed,
          timestamp: DateTime.add(base, 12, :second),
          correlation_id: "corr-2",
          provider: "claude"
        )

      e3 =
        build_event(
          id: "q_e_3",
          session_id: session_2.id,
          run_id: run_3.id,
          type: :message_received,
          timestamp: DateTime.add(base, 31, :second),
          correlation_id: "corr-3",
          provider: "claude"
        )

      {:ok, [stored_e1, stored_e2, stored_e3]} = SessionStore.append_events(store, [e1, e2, e3])

      %{
        session_1: session_1,
        session_2: session_2,
        session_3: session_3,
        run_1: run_1,
        run_2: run_2,
        run_3: run_3,
        stored_e1: stored_e1,
        stored_e2: stored_e2,
        stored_e3: stored_e3
      }
    end

    test "search_sessions supports filters, order, limit and cursor", %{
      store: store,
      query: query
    } do
      data = seed_session_with_runs_and_events(store)

      assert {:ok, %{sessions: sessions, total_count: count}} =
               QueryAPI.search_sessions(query, agent_id: "agent-q")

      assert count == 1
      assert Enum.map(sessions, & &1.id) == [data.session_1.id]

      assert {:ok, %{sessions: [active]}} = QueryAPI.search_sessions(query, status: :active)
      assert active.id == data.session_2.id

      assert {:ok, %{sessions: [completed]}} =
               QueryAPI.search_sessions(query, status: [:completed])

      assert completed.id == data.session_1.id

      assert {:ok, %{sessions: provider_sessions}} =
               QueryAPI.search_sessions(query, provider: "codex")

      assert Enum.map(provider_sessions, & &1.id) == [data.session_1.id]

      assert {:ok, %{sessions: deleted_hidden}} = QueryAPI.search_sessions(query)
      refute Enum.any?(deleted_hidden, &(&1.id == data.session_3.id))

      assert {:ok, %{sessions: deleted_included}} =
               QueryAPI.search_sessions(query, include_deleted: true)

      assert Enum.any?(deleted_included, &(&1.id == data.session_3.id))

      assert {:ok, %{sessions: [first], cursor: cursor}} =
               QueryAPI.search_sessions(query,
                 include_deleted: true,
                 order_by: :created_at_asc,
                 limit: 1
               )

      assert first.id == data.session_1.id
      assert is_binary(cursor)

      assert {:ok, %{sessions: [second]}} =
               QueryAPI.search_sessions(
                 query,
                 include_deleted: true,
                 order_by: :created_at_asc,
                 limit: 1,
                 cursor: cursor
               )

      assert second.id == data.session_2.id
    end

    test "search_sessions validates status and limit", %{query: query} do
      assert {:error, %Error{code: :validation_error}} =
               QueryAPI.search_sessions(query, status: :not_a_status)

      assert {:error, %Error{code: :validation_error}} =
               QueryAPI.search_sessions(query, limit: 0)
    end

    test "get_session_stats aggregates runs and events", %{store: store, query: query} do
      data = seed_session_with_runs_and_events(store)

      assert {:ok, stats} = QueryAPI.get_session_stats(query, data.session_1.id)
      assert stats.event_count == 2
      assert stats.run_count == 2
      assert stats.token_totals == %{input_tokens: 13, output_tokens: 9, total_tokens: 22}
      assert Enum.sort(stats.providers_used) == ["claude", "codex"]
      assert stats.status_counts == %{completed: 1, failed: 1}
      assert %DateTime{} = stats.first_event_at
      assert %DateTime{} = stats.last_event_at
    end

    test "get_session_stats returns session_not_found", %{query: query} do
      assert {:error, %Error{code: :session_not_found}} =
               QueryAPI.get_session_stats(query, "missing_session")
    end

    test "search_runs supports filters, min_tokens, order, cursor and limit", %{
      store: store,
      query: query
    } do
      data = seed_session_with_runs_and_events(store)

      assert {:ok, %{runs: runs}} = QueryAPI.search_runs(query, session_id: data.session_1.id)
      assert Enum.map(runs, & &1.id) |> Enum.sort() == [data.run_1.id, data.run_2.id]

      assert {:ok, %{runs: [claude_run]}} =
               QueryAPI.search_runs(query, provider: "claude", limit: 1)

      assert claude_run.provider == "claude"

      assert {:ok, %{runs: [failed_run]}} = QueryAPI.search_runs(query, status: :failed)
      assert failed_run.id == data.run_2.id

      assert {:ok, %{runs: [min_tokens_run]}} = QueryAPI.search_runs(query, min_tokens: 10)
      assert min_tokens_run.id == data.run_2.id

      assert {:ok, %{runs: ordered}} = QueryAPI.search_runs(query, order_by: :token_usage_desc)
      assert Enum.at(ordered, 0).id == data.run_2.id

      assert {:ok, %{runs: [page_1], cursor: cursor}} =
               QueryAPI.search_runs(query, order_by: :started_at_desc, limit: 1)

      assert is_binary(cursor)

      assert {:ok, %{runs: [page_2]}} =
               QueryAPI.search_runs(query, order_by: :started_at_desc, limit: 1, cursor: cursor)

      refute page_1.id == page_2.id
    end

    test "search_runs validates min_tokens and status", %{query: query} do
      assert {:error, %Error{code: :query_error}} = QueryAPI.search_runs(query, min_tokens: -1)

      assert {:error, %Error{code: :validation_error}} =
               QueryAPI.search_runs(query, status: :invalid)
    end

    test "get_usage_summary aggregates and supports filters", %{store: store, query: query} do
      data = seed_session_with_runs_and_events(store)

      assert {:ok, summary} = QueryAPI.get_usage_summary(query)
      assert summary.run_count == 3
      assert summary.total_tokens == 24
      assert summary.by_provider["claude"].run_count == 2

      assert {:ok, by_provider} = QueryAPI.get_usage_summary(query, provider: "codex")
      assert by_provider.run_count == 1
      assert by_provider.total_tokens == 15

      assert {:ok, by_session} = QueryAPI.get_usage_summary(query, session_id: data.session_1.id)
      assert by_session.run_count == 2

      assert {:ok, by_since} =
               QueryAPI.get_usage_summary(query,
                 since: DateTime.add(data.run_1.started_at, 5, :second)
               )

      assert by_since.run_count == 1
    end

    test "search_events supports filters, order, cursor and limit", %{store: store, query: query} do
      data = seed_session_with_runs_and_events(store)

      assert {:ok, %{events: events}} =
               QueryAPI.search_events(query,
                 session_ids: [data.session_1.id],
                 run_ids: [data.run_1.id],
                 types: [:run_started, :run_completed],
                 providers: ["claude"]
               )

      assert Enum.map(events, & &1.id) == [data.stored_e1.id, data.stored_e2.id]

      assert {:ok, %{events: [corr]}} = QueryAPI.search_events(query, correlation_id: "corr-3")
      assert corr.id == data.stored_e3.id

      assert {:ok, %{events: [latest]}} =
               QueryAPI.search_events(query, order_by: :timestamp_desc, limit: 1)

      assert latest.id == data.stored_e3.id

      assert {:ok, %{events: [page_1], cursor: cursor}} =
               QueryAPI.search_events(query, order_by: :sequence_asc, limit: 1)

      assert is_binary(cursor)

      assert {:ok, %{events: [page_2]}} =
               QueryAPI.search_events(query, order_by: :sequence_asc, limit: 1, cursor: cursor)

      refute page_1.id == page_2.id
    end

    test "search_events and count_events validate types", %{store: store, query: query} do
      data = seed_session_with_runs_and_events(store)

      assert {:ok, count} = QueryAPI.count_events(query, session_ids: [data.session_1.id])
      assert count == 2

      assert {:error, %Error{code: :validation_error}} =
               QueryAPI.search_events(query, types: [:not_a_type])
    end

    test "export_session includes runs/events and optional artifacts", %{
      store: store,
      query: query
    } do
      data = seed_session_with_runs_and_events(store)

      now = DateTime.utc_now()

      Ash.create!(
        Resources.Artifact,
        %{
          id: "q_art_1",
          session_id: data.session_1.id,
          run_id: data.run_1.id,
          key: "artifact/export/1",
          content_type: "application/json",
          byte_size: 42,
          checksum_sha256: String.duplicate("b", 64),
          storage_backend: "s3",
          storage_ref: "s3://bucket/export-1",
          metadata: %{},
          created_at: now
        },
        action: :create,
        domain: AgentSessionManager.Ash.TestDomain
      )

      assert {:ok, export} = QueryAPI.export_session(query, data.session_1.id)
      assert export.session.id == data.session_1.id
      assert length(export.runs) == 2
      assert length(export.events) == 2
      refute Map.has_key?(export, :artifacts)

      assert {:ok, export_with_artifacts} =
               QueryAPI.export_session(query, data.session_1.id, include_artifacts: true)

      assert length(export_with_artifacts.artifacts) == 1
      assert hd(export_with_artifacts.artifacts).id == "q_art_1"
    end

    test "export_session returns session_not_found", %{query: query} do
      assert {:error, %Error{code: :session_not_found}} =
               QueryAPI.export_session(query, "missing_session")
    end
  end
end
