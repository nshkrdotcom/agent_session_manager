#!/usr/bin/env elixir

defmodule PersistenceMaintenance.DemoRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :agent_session_manager,
    adapter: Ecto.Adapters.SQLite3
end

defmodule PersistenceMaintenance do
  @moduledoc false

  alias AgentSessionManager.Adapters.{EctoMaintenance, EctoSessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Core.{Event, Session}
  alias AgentSessionManager.Persistence.RetentionPolicy
  alias AgentSessionManager.Ports.{Maintenance, SessionStore}

  @db_path "/tmp/asm_persistence_maintenance_demo.db"
  @repo PersistenceMaintenance.DemoRepo

  def main(_args) do
    IO.puts("\n=== Persistence Maintenance Example ===\n")

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
    # 1. Start Ecto Repo + stores
    IO.puts("1. Starting Ecto Repo and stores")
    Application.put_env(:agent_session_manager, @repo, database: @db_path, pool_size: 1)
    {:ok, _} = @repo.start_link()
    Ecto.Migrator.up(@repo, 1, Migration, log: false)

    {:ok, store} = EctoSessionStore.start_link(repo: @repo)
    maint = {EctoMaintenance, @repo}
    IO.puts("   Store and maintenance engine started")

    # 2. Create sessions with varied ages and statuses
    IO.puts("\n2. Creating test sessions")

    sessions = [
      {"ses_recent_active", :active, 1},
      {"ses_recent_completed", :completed, 5},
      {"ses_old_completed", :completed, 100},
      {"ses_old_failed", :failed, 120},
      {"ses_pinned", :completed, 200}
    ]

    for {id, status, days_ago} <- sessions do
      {:ok, session} =
        Session.new(%{
          id: id,
          agent_id: "demo-agent",
          tags: if(id == "ses_pinned", do: ["pinned"], else: [])
        })

      session = %{session | status: status}

      created_at =
        DateTime.utc_now()
        |> DateTime.add(-days_ago, :day)
        |> DateTime.truncate(:microsecond)

      session = %{session | created_at: created_at, updated_at: created_at}
      :ok = SessionStore.save_session(store, session)

      # Add some events to each session
      for i <- 1..20 do
        type =
          Enum.random([
            :run_started,
            :message_received,
            :message_streamed,
            :token_usage_updated,
            :run_completed
          ])

        {:ok, event} =
          Event.new(%{type: type, session_id: id, run_id: "run_#{id}_#{i}", data: %{seq: i}})

        {:ok, _} = SessionStore.append_event_with_sequence(store, event)
      end

      IO.puts("   #{id}: status=#{status}, age=#{days_ago}d, 20 events")
    end

    # 3. Show pre-maintenance state
    IO.puts("\n3. Pre-maintenance state")
    {:ok, all_sessions} = SessionStore.list_sessions(store)
    IO.puts("   Total sessions: #{length(all_sessions)}")

    for s <- all_sessions do
      {:ok, events} = SessionStore.get_events(store, s.id)

      IO.puts(
        "   #{s.id}: #{s.status}, #{length(events)} events, deleted_at=#{inspect(s.deleted_at)}"
      )
    end

    # 4. Define and execute retention policy (soft delete)
    IO.puts("\n4. Executing retention policy (soft-delete old completed sessions)")

    policy =
      RetentionPolicy.new(
        max_completed_session_age_days: 90,
        hard_delete_after_days: :infinity,
        max_events_per_session: 10,
        exempt_tags: ["pinned"]
      )

    {:ok, report} = Maintenance.execute(maint, policy)

    IO.puts("   Soft-deleted: #{report.sessions_soft_deleted}")
    IO.puts("   Hard-deleted: #{report.sessions_hard_deleted}")
    IO.puts("   Events pruned: #{report.events_pruned}")
    IO.puts("   Artifacts cleaned: #{report.artifacts_cleaned}")
    IO.puts("   Orphaned sequences: #{report.orphaned_sequences_cleaned}")
    IO.puts("   Duration: #{report.duration_ms}ms")
    IO.puts("   Errors: #{inspect(report.errors)}")

    # 5. Show post-maintenance state
    IO.puts("\n5. Post-maintenance state")
    {:ok, after_sessions} = SessionStore.list_sessions(store)

    for s <- after_sessions do
      {:ok, events} = SessionStore.get_events(store, s.id)

      IO.puts(
        "   #{s.id}: #{s.status}, #{length(events)} events, deleted_at=#{inspect(s.deleted_at)}"
      )
    end

    # 6. Run health check
    IO.puts("\n6. Running health check")
    {:ok, issues} = Maintenance.health_check(maint)

    if issues == [] do
      IO.puts("   Health check: HEALTHY (no issues)")
    else
      IO.puts("   Health check found #{length(issues)} issues:")
      for issue <- issues, do: IO.puts("   - #{issue}")
    end

    # 7. Execute hard delete
    IO.puts("\n7. Executing hard delete (sessions soft-deleted > 0 days ago)")
    hard_policy = RetentionPolicy.new(hard_delete_after_days: 1)
    {:ok, hard_report} = Maintenance.execute(maint, hard_policy)
    IO.puts("   Hard-deleted: #{hard_report.sessions_hard_deleted}")

    {:ok, final_sessions} = SessionStore.list_sessions(store)
    IO.puts("   Remaining sessions: #{length(final_sessions)}")

    for s <- final_sessions do
      IO.puts("   #{s.id}: #{s.status}")
    end

    # 8. Clean up
    IO.puts("\n8. Cleaning up")
    GenServer.stop(store)
    :ok
  end

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
  end
end

PersistenceMaintenance.main(System.argv())
