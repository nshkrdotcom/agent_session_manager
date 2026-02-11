defmodule AgentSessionManager.Adapters.EctoQueryAPITest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.EctoQueryAPI
  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.{QueryAPI, SessionStore}

  defmodule QueryTestRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_query_api_test.db")

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, QueryTestRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = QueryTestRepo.start_link()
    Ecto.Migrator.up(QueryTestRepo, 1, Migration, log: false)

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

  setup do
    # Clean between tests
    QueryTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.EventSchema)
    QueryTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.RunSchema)
    QueryTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.ArtifactSchema)

    QueryTestRepo.delete_all(
      AgentSessionManager.Adapters.EctoSessionStore.Schemas.SessionSequenceSchema
    )

    QueryTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.SessionSchema)

    {:ok, store} = EctoSessionStore.start_link(repo: QueryTestRepo)
    %{store: store, query: {EctoQueryAPI, QueryTestRepo}}
  end

  defp seed_session(store, id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "agent-1")
    status = Keyword.get(opts, :status, :active)
    tags = Keyword.get(opts, :tags, [])
    created_at = Keyword.get(opts, :created_at)
    updated_at = Keyword.get(opts, :updated_at)

    {:ok, session} = Session.new(%{id: id, agent_id: agent_id, tags: tags})

    session =
      session
      |> Map.put(:status, status)
      |> maybe_put_datetime(:created_at, created_at)
      |> maybe_put_datetime(:updated_at, updated_at)

    :ok = SessionStore.save_session(store, session)
    session
  end

  defp seed_run(store, session_id, run_id, opts \\ []) do
    provider = Keyword.get(opts, :provider, "claude")
    status = Keyword.get(opts, :status, :completed)
    input_tokens = Keyword.get(opts, :input_tokens, 100)
    output_tokens = Keyword.get(opts, :output_tokens, 50)
    started_at = Keyword.get(opts, :started_at)

    {:ok, run} = Run.new(%{id: run_id, session_id: session_id})

    run = %{
      run
      | provider: provider,
        status: status,
        token_usage: %{
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: input_tokens + output_tokens
        },
        started_at: started_at || run.started_at
    }

    :ok = SessionStore.save_run(store, run)
    run
  end

  defp seed_event(store, session_id, run_id, type, opts \\ []) do
    provider = Keyword.get(opts, :provider, "claude")
    correlation_id = Keyword.get(opts, :correlation_id)
    timestamp = Keyword.get(opts, :timestamp)

    {:ok, event} =
      Event.new(%{
        type: type,
        session_id: session_id,
        run_id: run_id,
        provider: provider,
        correlation_id: correlation_id,
        data: Keyword.get(opts, :data, %{})
      })

    event =
      if timestamp do
        %{event | timestamp: timestamp}
      else
        event
      end

    {:ok, persisted} = SessionStore.append_event_with_sequence(store, event)
    persisted
  end

  defp maybe_put_datetime(item, _field, nil), do: item
  defp maybe_put_datetime(item, field, %DateTime{} = value), do: Map.put(item, field, value)

  # ============================================================================
  # search_sessions
  # ============================================================================

  describe "search_sessions/2" do
    test "returns all sessions by default", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_session(store, "ses_2")

      {:ok, %{sessions: sessions, total_count: count}} = QueryAPI.search_sessions(query)
      assert count == 2
      assert length(sessions) == 2
    end

    test "filters by agent_id", %{store: store, query: query} do
      seed_session(store, "ses_1", agent_id: "agent-a")
      seed_session(store, "ses_2", agent_id: "agent-b")

      {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "agent-a")
      assert length(sessions) == 1
      assert hd(sessions).agent_id == "agent-a"
    end

    test "filters by status", %{store: store, query: query} do
      seed_session(store, "ses_1", status: :active)
      seed_session(store, "ses_2", status: :completed)

      {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, status: :completed)
      assert length(sessions) == 1
      assert hd(sessions).status == :completed
    end

    test "respects limit", %{store: store, query: query} do
      for i <- 1..5, do: seed_session(store, "ses_#{i}")

      {:ok, %{sessions: sessions, total_count: count}} =
        QueryAPI.search_sessions(query, limit: 2)

      assert length(sessions) == 2
      assert count == 5
    end

    test "excludes soft-deleted sessions by default", %{store: store, query: query} do
      session = seed_session(store, "ses_1")

      deleted = %{session | deleted_at: DateTime.utc_now()}
      :ok = SessionStore.save_session(store, deleted)

      seed_session(store, "ses_2")

      {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query)
      assert length(sessions) == 1
    end

    test "includes soft-deleted when requested", %{store: store, query: query} do
      session = seed_session(store, "ses_1")
      deleted = %{session | deleted_at: DateTime.utc_now()}
      :ok = SessionStore.save_session(store, deleted)

      seed_session(store, "ses_2")

      {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, include_deleted: true)
      assert length(sessions) == 2
    end

    test "returns cursor for pagination", %{store: store, query: query} do
      seed_session(store, "ses_1")

      {:ok, %{cursor: cursor}} = QueryAPI.search_sessions(query)
      assert is_binary(cursor)
    end

    test "filters by provider across runs", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_session(store, "ses_2")
      seed_run(store, "ses_1", "run_1", provider: "claude")
      seed_run(store, "ses_2", "run_2", provider: "codex")

      {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, provider: "claude")
      assert length(sessions) == 1
      assert hd(sessions).id == "ses_1"
    end

    test "filters by tags", %{store: store, query: query} do
      seed_session(store, "ses_1", tags: ["alpha", "beta"])
      seed_session(store, "ses_2", tags: ["beta"])

      {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, tags: ["alpha"])
      assert length(sessions) == 1
      assert hd(sessions).id == "ses_1"
    end

    test "cursor pagination returns different results when cursor is provided", %{
      store: store,
      query: query
    } do
      base = ~U[2026-02-10 00:00:00.000000Z]
      older = DateTime.add(base, 10, :second)
      middle = DateTime.add(base, 20, :second)
      newest = DateTime.add(base, 30, :second)

      seed_session(store, "ses_old", created_at: older, updated_at: older)
      seed_session(store, "ses_mid", created_at: middle, updated_at: middle)
      seed_session(store, "ses_new", created_at: newest, updated_at: newest)

      {:ok, %{sessions: [first], cursor: cursor}} =
        QueryAPI.search_sessions(query, limit: 1, order_by: :updated_at_desc)

      {:ok, %{sessions: [second]}} =
        QueryAPI.search_sessions(query, limit: 1, order_by: :updated_at_desc, cursor: cursor)

      refute first.id == second.id
      assert first.id == "ses_new"
      assert second.id == "ses_mid"
    end

    test "cursor respects created_at_desc ordering", %{store: store, query: query} do
      base = ~U[2026-02-10 01:00:00.000000Z]
      first_ts = DateTime.add(base, 10, :second)
      second_ts = DateTime.add(base, 20, :second)
      third_ts = DateTime.add(base, 30, :second)

      seed_session(store, "ses_1", created_at: first_ts, updated_at: first_ts)
      seed_session(store, "ses_2", created_at: second_ts, updated_at: second_ts)
      seed_session(store, "ses_3", created_at: third_ts, updated_at: third_ts)

      {:ok, %{sessions: [page_1], cursor: cursor}} =
        QueryAPI.search_sessions(query, limit: 1, order_by: :created_at_desc)

      {:ok, %{sessions: [page_2]}} =
        QueryAPI.search_sessions(query, limit: 1, order_by: :created_at_desc, cursor: cursor)

      assert page_1.id == "ses_3"
      assert page_2.id == "ses_2"
    end

    test "rejects negative limits", %{query: query} do
      assert {:error, error} = QueryAPI.search_sessions(query, limit: -1)
      assert error.code == :validation_error
    end

    test "rejects invalid status filter values", %{query: query} do
      assert {:error, error} = QueryAPI.search_sessions(query, status: %{bad: "value"})
      assert error.code == :validation_error

      assert {:error, error} = QueryAPI.search_sessions(query, status: :does_not_exist)
      assert error.code == :validation_error
    end
  end

  # ============================================================================
  # get_session_stats
  # ============================================================================

  describe "get_session_stats/2" do
    test "returns stats for a session", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1", provider: "claude", input_tokens: 100, output_tokens: 50)
      seed_run(store, "ses_1", "run_2", provider: "codex", input_tokens: 200, output_tokens: 80)
      seed_event(store, "ses_1", "run_1", :run_started)
      seed_event(store, "ses_1", "run_1", :run_completed)
      seed_event(store, "ses_1", "run_2", :run_started)

      {:ok, stats} = QueryAPI.get_session_stats(query, "ses_1")
      assert stats.event_count == 3
      assert stats.run_count == 2
      assert stats.token_totals.input_tokens == 300
      assert stats.token_totals.output_tokens == 130
      assert "claude" in stats.providers_used
      assert "codex" in stats.providers_used
    end

    test "returns error for missing session", %{query: query} do
      {:error, error} = QueryAPI.get_session_stats(query, "nonexistent")
      assert error.code == :session_not_found
    end
  end

  # ============================================================================
  # search_runs
  # ============================================================================

  describe "search_runs/2" do
    test "returns all runs", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1")
      seed_run(store, "ses_1", "run_2")

      {:ok, %{runs: runs}} = QueryAPI.search_runs(query)
      assert length(runs) == 2
    end

    test "filters by provider", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1", provider: "claude")
      seed_run(store, "ses_1", "run_2", provider: "codex")

      {:ok, %{runs: runs}} = QueryAPI.search_runs(query, provider: "claude")
      assert length(runs) == 1
      assert hd(runs).provider == "claude"
    end

    test "filters by session_id", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_session(store, "ses_2")
      seed_run(store, "ses_1", "run_1")
      seed_run(store, "ses_2", "run_2")

      {:ok, %{runs: runs}} = QueryAPI.search_runs(query, session_id: "ses_1")
      assert length(runs) == 1
    end

    test "filters by min_tokens", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1", input_tokens: 50, output_tokens: 25)
      seed_run(store, "ses_1", "run_2", input_tokens: 200, output_tokens: 50)

      {:ok, %{runs: runs}} = QueryAPI.search_runs(query, min_tokens: 200)
      assert length(runs) == 1
      assert hd(runs).id == "run_2"
    end

    test "orders by token usage descending", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1", input_tokens: 10, output_tokens: 5)
      seed_run(store, "ses_1", "run_2", input_tokens: 200, output_tokens: 50)

      {:ok, %{runs: runs}} = QueryAPI.search_runs(query, order_by: :token_usage_desc)
      assert length(runs) == 2
      assert Enum.at(runs, 0).id == "run_2"
      assert Enum.at(runs, 1).id == "run_1"
    end

    test "cursor respects started_at_desc ordering", %{store: store, query: query} do
      seed_session(store, "ses_1")
      base = ~U[2026-02-10 02:00:00.000000Z]

      seed_run(store, "ses_1", "run_1", started_at: DateTime.add(base, 10, :second))
      seed_run(store, "ses_1", "run_2", started_at: DateTime.add(base, 20, :second))
      seed_run(store, "ses_1", "run_3", started_at: DateTime.add(base, 30, :second))

      {:ok, %{runs: [page_1], cursor: cursor}} =
        QueryAPI.search_runs(query, limit: 1, order_by: :started_at_desc)

      {:ok, %{runs: [page_2]}} =
        QueryAPI.search_runs(query, limit: 1, order_by: :started_at_desc, cursor: cursor)

      assert page_1.id == "run_3"
      assert page_2.id == "run_2"
    end

    test "rejects unbounded limits", %{query: query} do
      assert {:error, error} = QueryAPI.search_runs(query, limit: 100_000)
      assert error.code == :validation_error
    end
  end

  # ============================================================================
  # get_usage_summary
  # ============================================================================

  describe "get_usage_summary/2" do
    test "aggregates token usage across runs", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1", provider: "claude", input_tokens: 100, output_tokens: 50)
      seed_run(store, "ses_1", "run_2", provider: "codex", input_tokens: 200, output_tokens: 80)

      {:ok, summary} = QueryAPI.get_usage_summary(query)
      assert summary.total_input_tokens == 300
      assert summary.total_output_tokens == 130
      assert summary.total_tokens == 430
      assert summary.run_count == 2
      assert summary.by_provider["claude"].input_tokens == 100
      assert summary.by_provider["codex"].input_tokens == 200
    end

    test "filters by provider", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1", provider: "claude", input_tokens: 100, output_tokens: 50)
      seed_run(store, "ses_1", "run_2", provider: "codex", input_tokens: 200, output_tokens: 80)

      {:ok, summary} = QueryAPI.get_usage_summary(query, provider: "claude")
      assert summary.run_count == 1
      assert summary.total_input_tokens == 100
    end
  end

  # ============================================================================
  # search_events / count_events
  # ============================================================================

  describe "search_events/2" do
    test "returns events filtered by session", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_session(store, "ses_2")
      seed_event(store, "ses_1", "run_1", :run_started)
      seed_event(store, "ses_2", "run_2", :run_started)

      {:ok, %{events: events}} = QueryAPI.search_events(query, session_ids: ["ses_1"])
      assert length(events) == 1
    end

    test "filters by event type", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_event(store, "ses_1", "run_1", :run_started)
      seed_event(store, "ses_1", "run_1", :run_completed, data: %{stop_reason: "done"})

      {:ok, %{events: events}} =
        QueryAPI.search_events(query, session_ids: ["ses_1"], types: [:run_started])

      assert length(events) == 1
      assert hd(events).type == :run_started
    end

    test "filters by correlation_id", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_event(store, "ses_1", "run_1", :run_started, correlation_id: "corr_1")
      seed_event(store, "ses_1", "run_1", :run_completed, correlation_id: "corr_2")

      {:ok, %{events: events}} = QueryAPI.search_events(query, correlation_id: "corr_1")
      assert length(events) == 1
    end

    test "keeps unknown JSON keys as strings in projected events", %{store: store, query: query} do
      seed_session(store, "ses_1")
      unique_key = "unknown_key_#{System.unique_integer([:positive, :monotonic])}"
      nested_key = "nested_key_#{System.unique_integer([:positive, :monotonic])}"

      seed_event(
        store,
        "ses_1",
        "run_1",
        :message_received,
        data: %{unique_key => %{nested_key => "value"}}
      )

      {:ok, %{events: [event]}} = QueryAPI.search_events(query, session_ids: ["ses_1"])
      assert event.data == %{unique_key => %{nested_key => "value"}}
    end

    test "cursor respects timestamp_desc ordering", %{store: store, query: query} do
      seed_session(store, "ses_1")
      base = ~U[2026-02-10 03:00:00.000000Z]

      seed_event(store, "ses_1", "run_1", :run_started,
        timestamp: DateTime.add(base, 10, :second)
      )

      seed_event(store, "ses_1", "run_1", :message_received,
        timestamp: DateTime.add(base, 20, :second)
      )

      seed_event(store, "ses_1", "run_1", :run_completed,
        timestamp: DateTime.add(base, 30, :second)
      )

      {:ok, %{events: [page_1], cursor: cursor}} =
        QueryAPI.search_events(query, session_ids: ["ses_1"], order_by: :timestamp_desc, limit: 1)

      {:ok, %{events: [page_2]}} =
        QueryAPI.search_events(query,
          session_ids: ["ses_1"],
          order_by: :timestamp_desc,
          limit: 1,
          cursor: cursor
        )

      assert page_1.type == :run_completed
      assert page_2.type == :message_received
    end

    test "rejects negative limits", %{query: query} do
      assert {:error, error} = QueryAPI.search_events(query, limit: -10)
      assert error.code == :validation_error
    end

    test "rejects unknown event types", %{query: query} do
      assert {:error, error} = QueryAPI.search_events(query, types: [:not_a_real_event])
      assert error.code == :validation_error
    end
  end

  describe "count_events/2" do
    test "counts events matching filters", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_event(store, "ses_1", "run_1", :run_started)
      seed_event(store, "ses_1", "run_1", :message_received)
      seed_event(store, "ses_1", "run_1", :run_completed)

      {:ok, count} = QueryAPI.count_events(query, session_ids: ["ses_1"])
      assert count == 3

      {:ok, count} =
        QueryAPI.count_events(query, session_ids: ["ses_1"], types: [:run_started])

      assert count == 1
    end
  end

  # ============================================================================
  # export_session
  # ============================================================================

  describe "export_session/3" do
    test "exports full session data", %{store: store, query: query} do
      seed_session(store, "ses_1")
      seed_run(store, "ses_1", "run_1")
      seed_event(store, "ses_1", "run_1", :run_started)
      seed_event(store, "ses_1", "run_1", :run_completed)

      {:ok, export} = QueryAPI.export_session(query, "ses_1")
      assert %Session{} = export.session
      assert length(export.runs) == 1
      assert length(export.events) == 2
    end

    test "returns error for missing session", %{query: query} do
      {:error, error} = QueryAPI.export_session(query, "nonexistent")
      assert error.code == :session_not_found
    end
  end
end
