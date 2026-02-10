#!/usr/bin/env elixir

defmodule EctoSessionStoreLive.DemoRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :agent_session_manager,
    adapter: Ecto.Adapters.SQLite3
end

defmodule EctoSessionStoreLive do
  @moduledoc false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV2
  alias AgentSessionManager.Core.{Event, Session}
  alias AgentSessionManager.Ports.SessionStore

  @db_path "/tmp/asm_ecto_live_demo.db"
  @repo EctoSessionStoreLive.DemoRepo

  def main(_args) do
    IO.puts("\n=== EctoSessionStore Live Example ===\n")

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
    # 1. Start the Ecto Repo backed by SQLite
    IO.puts("1. Starting Ecto Repo with SQLite backend")

    Application.put_env(:agent_session_manager, @repo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, _} = @repo.start_link()
    create_tables()
    IO.puts("   Repo started and tables created")

    # 2. Start the EctoSessionStore adapter
    IO.puts("\n2. Starting EctoSessionStore")
    {:ok, store} = EctoSessionStore.start_link(repo: @repo)
    IO.puts("   Store started: #{inspect(store)}")

    # 3. Create and save a session
    IO.puts("\n3. Saving a session")

    session = %Session{
      id: "ses_ecto_demo_001",
      agent_id: "demo-agent",
      status: :active,
      metadata: %{user: "example", source: "ecto"},
      context: %{system_prompt: "You are a helpful assistant"},
      tags: ["demo", "ecto"],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ok = SessionStore.save_session(store, session)
    IO.puts("   Session saved: #{session.id}")

    # 4. Retrieve and verify
    IO.puts("\n4. Retrieving session")
    {:ok, retrieved} = SessionStore.get_session(store, session.id)
    IO.puts("   ID: #{retrieved.id}")
    IO.puts("   Agent: #{retrieved.agent_id}")
    IO.puts("   Status: #{retrieved.status}")
    IO.puts("   Tags: #{inspect(retrieved.tags)}")

    # 5. Append events with sequencing
    IO.puts("\n5. Appending events")

    event_types = [:session_created, :run_started, :message_received, :run_completed]

    for {type, i} <- Enum.with_index(event_types, 1) do
      {:ok, event} =
        Event.new(%{
          type: type,
          session_id: session.id,
          run_id: "run_ecto_001",
          data: %{content: "Event #{i}"}
        })

      {:ok, stored} = SessionStore.append_event_with_sequence(store, event)
      IO.puts("   Event #{i}: #{type} -> seq=#{stored.sequence_number}")
    end

    # 6. Query events
    IO.puts("\n6. Querying events")
    {:ok, all_events} = SessionStore.get_events(store, session.id)
    IO.puts("   Total events: #{length(all_events)}")

    {:ok, latest} = SessionStore.get_latest_sequence(store, session.id)
    IO.puts("   Latest sequence: #{latest}")

    # 7. List sessions
    IO.puts("\n7. Listing sessions")
    {:ok, sessions} = SessionStore.list_sessions(store)
    IO.puts("   Total sessions: #{length(sessions)}")

    # 8. Clean up
    IO.puts("\n8. Cleaning up")
    :ok = SessionStore.delete_session(store, session.id)
    {:ok, []} = SessionStore.list_sessions(store)
    IO.puts("   Session deleted")

    GenServer.stop(store)
    :ok
  end

  defp create_tables do
    Ecto.Migrator.up(@repo, 1, Migration, log: false)
    Ecto.Migrator.up(@repo, 2, MigrationV2, log: false)
  end

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
  end
end

EctoSessionStoreLive.main(System.argv())
