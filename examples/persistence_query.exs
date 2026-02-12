#!/usr/bin/env elixir

defmodule PersistenceQuery.DemoRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :agent_session_manager,
    adapter: Ecto.Adapters.SQLite3
end

defmodule PersistenceQuery do
  @moduledoc false

  alias AgentSessionManager.Adapters.{EctoQueryAPI, EctoSessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.{QueryAPI, SessionStore}

  @db_path "/tmp/asm_persistence_query_demo.db"
  @repo PersistenceQuery.DemoRepo

  def main(_args) do
    IO.puts("\n=== Persistence Query API Example ===\n")

    cleanup()

    case run() do
      :ok ->
        IO.puts("\nAll checks passed!")
        cleanup()
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{inspect(reason)}")
        cleanup()
        System.halt(1)
    end
  end

  defp run do
    # 1. Start stores
    IO.puts("1. Starting Ecto Repo, SessionStore, and QueryAPI")
    Application.put_env(:agent_session_manager, @repo, database: @db_path, pool_size: 1)
    {:ok, _} = @repo.start_link()
    Ecto.Migrator.up(@repo, 1, Migration, log: false)

    {:ok, store} = EctoSessionStore.start_link(repo: @repo)
    query = {EctoQueryAPI, @repo}
    IO.puts("   All stores started")

    # 2. Seed data
    IO.puts("\n2. Seeding test data (3 sessions, multiple providers)")
    seed_data(store)

    # 3. Search sessions
    IO.puts("\n3. Search sessions by agent_id")

    {:ok, %{sessions: sessions, total_count: count}} =
      QueryAPI.search_sessions(query, agent_id: "agent-alpha")

    IO.puts("   Found #{count} sessions for agent-alpha:")
    for s <- sessions, do: IO.puts("   - #{s.id} (#{s.status})")

    # 4. Search sessions with status filter
    IO.puts("\n4. Search sessions by status")

    {:ok, %{sessions: completed}} =
      QueryAPI.search_sessions(query, status: :completed)

    IO.puts("   Completed sessions: #{length(completed)}")

    # 5. Search runs by provider
    IO.puts("\n5. Search runs by provider")

    for provider <- ["claude", "codex", "amp"] do
      {:ok, %{runs: runs}} = QueryAPI.search_runs(query, provider: provider)
      IO.puts("   #{provider}: #{length(runs)} runs")
    end

    # 6. Get usage summary
    IO.puts("\n6. Token usage summary")
    {:ok, summary} = QueryAPI.get_usage_summary(query)
    IO.puts("   Total runs: #{summary.run_count}")
    IO.puts("   Total tokens: #{summary.total_tokens}")
    IO.puts("   Input tokens: #{summary.total_input_tokens}")
    IO.puts("   Output tokens: #{summary.total_output_tokens}")
    IO.puts("   By provider:")

    for {provider, stats} <- summary.by_provider do
      IO.puts("     #{provider}: #{stats.run_count} runs, #{stats.total_tokens} tokens")
    end

    # 7. Get session stats
    IO.puts("\n7. Session stats for ses_alpha")
    {:ok, stats} = QueryAPI.get_session_stats(query, "ses_alpha")
    IO.puts("   Events: #{stats.event_count}")
    IO.puts("   Runs: #{stats.run_count}")
    IO.puts("   Providers: #{inspect(stats.providers_used)}")
    IO.puts("   Token totals: #{inspect(stats.token_totals)}")
    IO.puts("   Run statuses: #{inspect(stats.status_counts)}")

    # 8. Search events by type
    IO.puts("\n8. Search events by type")

    {:ok, %{events: tool_events}} =
      QueryAPI.search_events(query, session_ids: ["ses_alpha"], types: [:tool_call_started])

    IO.puts("   tool_call_started events in ses_alpha: #{length(tool_events)}")

    # 9. Count events
    IO.puts("\n9. Count events (without loading)")

    {:ok, total} =
      QueryAPI.count_events(query, session_ids: ["ses_alpha", "ses_beta", "ses_gamma"])

    IO.puts("   Total events across all sessions: #{total}")

    # 10. Export session
    IO.puts("\n10. Export session")
    {:ok, export} = QueryAPI.export_session(query, "ses_alpha")
    IO.puts("   Session: #{export.session.id}")
    IO.puts("   Runs: #{length(export.runs)}")
    IO.puts("   Events: #{length(export.events)}")

    # 11. Paginated search
    IO.puts("\n11. Paginated event search (limit 5)")

    {:ok, %{events: page1, cursor: cursor}} =
      QueryAPI.search_events(query, session_ids: ["ses_alpha"], limit: 5)

    IO.puts("   Page 1: #{length(page1)} events")
    IO.puts("   Cursor: #{if cursor, do: String.slice(cursor, 0, 30) <> "...", else: "nil"}")

    # 12. Clean up
    IO.puts("\n12. Cleaning up")
    GenServer.stop(store)
    :ok
  end

  defp seed_data(store) do
    # Session Alpha: 2 Claude runs
    create_session(store, "ses_alpha", "agent-alpha", :completed)
    create_run(store, "ses_alpha", "run_a1", "claude", 500, 200)
    create_run(store, "ses_alpha", "run_a2", "claude", 300, 150)

    seed_events(store, "ses_alpha", "run_a1", [
      :run_started,
      :message_received,
      :tool_call_started,
      :tool_call_completed,
      :message_received,
      :run_completed
    ])

    seed_events(store, "ses_alpha", "run_a2", [:run_started, :message_received, :run_completed])

    # Session Beta: 1 Codex run
    create_session(store, "ses_beta", "agent-alpha", :completed)
    create_run(store, "ses_beta", "run_b1", "codex", 400, 180)
    seed_events(store, "ses_beta", "run_b1", [:run_started, :message_received, :run_completed])

    # Session Gamma: 1 Amp run
    create_session(store, "ses_gamma", "agent-beta", :active)
    create_run(store, "ses_gamma", "run_g1", "amp", 600, 250)

    seed_events(store, "ses_gamma", "run_g1", [
      :run_started,
      :message_received,
      :message_streamed,
      :run_completed
    ])

    IO.puts("   3 sessions, 4 runs, 16 events seeded")
  end

  defp create_session(store, id, agent_id, status) do
    {:ok, session} = Session.new(%{id: id, agent_id: agent_id})
    :ok = SessionStore.save_session(store, %{session | status: status})
  end

  defp create_run(store, session_id, run_id, provider, input_tokens, output_tokens) do
    {:ok, run} = Run.new(%{id: run_id, session_id: session_id})

    run = %{
      run
      | provider: provider,
        status: :completed,
        token_usage: %{
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: input_tokens + output_tokens
        }
    }

    :ok = SessionStore.save_run(store, run)
  end

  defp seed_events(store, session_id, run_id, types) do
    for type <- types do
      {:ok, event} = Event.new(%{type: type, session_id: session_id, run_id: run_id, data: %{}})
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)
    end
  end

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
  end
end

PersistenceQuery.main(System.argv())
