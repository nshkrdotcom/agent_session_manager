#!/usr/bin/env elixir

defmodule SQLiteSessionStoreLive do
  @moduledoc false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Core.{Event, Session}
  alias AgentSessionManager.Ports.SessionStore

  defmodule DemoRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path "/tmp/asm_ecto_sqlite_live_demo.db"
  @repo DemoRepo

  def main(_args) do
    IO.puts("\n=== SQLite via EctoSessionStore Live Example ===\n")

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
    # 1. Start Repo + store
    IO.puts("1. Starting SQLite Repo at #{@db_path}")
    configure_repo()
    {:ok, repo_pid} = @repo.start_link()
    :ok = ensure_migrations()
    {:ok, store} = EctoSessionStore.start_link(repo: @repo)
    IO.puts("   Store started: #{inspect(store)}")

    # 2. Create and save a session
    IO.puts("\n2. Saving a session")

    session = %Session{
      id: "ses_demo_001",
      agent_id: "demo-agent",
      status: :active,
      metadata: %{user: "example", environment: "development"},
      context: %{system_prompt: "You are a helpful assistant"},
      tags: ["demo", "sqlite"],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ok = SessionStore.save_session(store, session)
    IO.puts("   Session saved: #{session.id}")

    # 3. Retrieve and verify session
    IO.puts("\n3. Retrieving session")
    {:ok, retrieved} = SessionStore.get_session(store, session.id)
    IO.puts("   ID: #{retrieved.id}")
    IO.puts("   Agent: #{retrieved.agent_id}")
    IO.puts("   Status: #{retrieved.status}")
    IO.puts("   Tags: #{inspect(retrieved.tags)}")

    # 4. Append events with auto-sequencing
    IO.puts("\n4. Appending events with sequence numbers")

    event_types = [
      :session_created,
      :run_started,
      :message_received,
      :message_sent,
      :run_completed
    ]

    for {type, i} <- Enum.with_index(event_types, 1) do
      {:ok, event} =
        Event.new(%{
          type: type,
          session_id: session.id,
          run_id: "run_demo_001",
          data: %{content: "Event #{i}"}
        })

      {:ok, stored} = SessionStore.append_event_with_sequence(store, event)
      IO.puts("   Event #{i}: #{type} -> seq=#{stored.sequence_number}")
    end

    # 5. Query events with filters
    IO.puts("\n5. Querying events")

    {:ok, all_events} = SessionStore.get_events(store, session.id)
    IO.puts("   Total events: #{length(all_events)}")

    {:ok, after_2} = SessionStore.get_events(store, session.id, after: 2)
    IO.puts("   Events after seq 2: #{length(after_2)}")

    {:ok, limited} = SessionStore.get_events(store, session.id, limit: 2)
    IO.puts("   Events (limit 2): #{length(limited)}")

    # 6. Check latest sequence
    IO.puts("\n6. Checking latest sequence")
    {:ok, latest} = SessionStore.get_latest_sequence(store, session.id)
    IO.puts("   Latest sequence: #{latest}")

    # 7. List sessions
    IO.puts("\n7. Listing sessions")
    {:ok, sessions} = SessionStore.list_sessions(store)
    IO.puts("   Total sessions: #{length(sessions)}")

    # 8. Demonstrate persistence across restarts
    IO.puts("\n8. Demonstrating persistence across restart")
    GenServer.stop(store)
    IO.puts("   Store stopped")

    {:ok, store2} = EctoSessionStore.start_link(repo: @repo)
    IO.puts("   Store restarted")

    {:ok, survived} = SessionStore.get_session(store2, session.id)
    IO.puts("   Session survived restart: #{survived.id} (status: #{survived.status})")

    {:ok, events_survived} = SessionStore.get_events(store2, session.id)
    IO.puts("   Events survived: #{length(events_survived)}")

    {:ok, seq_survived} = SessionStore.get_latest_sequence(store2, session.id)
    IO.puts("   Sequence survived: #{seq_survived}")

    # 9. Cleanup
    IO.puts("\n9. Deleting session")
    :ok = SessionStore.delete_session(store2, session.id)
    {:ok, []} = SessionStore.list_sessions(store2)
    IO.puts("   Session deleted, store empty")

    GenServer.stop(store2)
    if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
    :ok
  end

  defp configure_repo do
    Application.put_env(:agent_session_manager, @repo,
      database: @db_path,
      pool_size: 1
    )
  end

  defp ensure_migrations do
    :ok = run_migration(1, Migration)
  end

  defp run_migration(version, migration) do
    case Ecto.Migrator.up(@repo, version, migration, log: false) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end
  end

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
  end
end

SQLiteSessionStoreLive.main(System.argv())
