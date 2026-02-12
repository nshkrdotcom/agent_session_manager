#!/usr/bin/env elixir

defmodule CompositeStoreLive do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    CompositeSessionStore,
    EctoSessionStore,
    EctoSessionStore.Migration,
    FileArtifactStore
  }

  alias AgentSessionManager.Core.{Event, Session}
  alias AgentSessionManager.Ports.{ArtifactStore, SessionStore}

  defmodule DemoRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path "/tmp/asm_ecto_composite_live_demo.db"
  @artifact_root "/tmp/asm_composite_live_artifacts"

  def main(_args) do
    IO.puts("\n=== CompositeSessionStore Live Example ===\n")

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
    # 1. Start backend stores
    IO.puts("1. Starting backend stores")
    configure_repo()
    {:ok, repo_pid} = DemoRepo.start_link()
    :ok = ensure_migrations()
    {:ok, session_store} = EctoSessionStore.start_link(repo: DemoRepo)
    IO.puts("   Ecto session store (SQLite): #{inspect(session_store)}")

    {:ok, file_store} = FileArtifactStore.start_link(root: @artifact_root)
    IO.puts("   File artifact store: #{inspect(file_store)}")

    # 2. Create composite
    IO.puts("\n2. Creating CompositeSessionStore")

    {:ok, composite} =
      CompositeSessionStore.start_link(
        session_store: session_store,
        artifact_store: file_store
      )

    IO.puts("   Composite store: #{inspect(composite)}")

    # 3. Use session operations (delegated to Ecto/SQLite)
    IO.puts("\n3. Session operations (-> Ecto/SQLite)")

    session = %Session{
      id: "ses_comp_001",
      agent_id: "composite-agent",
      status: :active,
      metadata: %{},
      context: %{system_prompt: "Be helpful"},
      tags: ["composite"],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ok = SessionStore.save_session(composite, session)
    {:ok, retrieved} = SessionStore.get_session(composite, session.id)
    IO.puts("   Session saved and retrieved: #{retrieved.id} (#{retrieved.status})")

    # 4. Use event operations (delegated to Ecto/SQLite)
    IO.puts("\n4. Event operations (-> Ecto/SQLite)")

    for {type, i} <- Enum.with_index([:session_created, :run_started, :run_completed], 1) do
      {:ok, event} =
        Event.new(%{type: type, session_id: session.id, data: %{step: i}})

      {:ok, stored} = SessionStore.append_event_with_sequence(composite, event)
      IO.puts("   Event #{i}: #{type} -> seq=#{stored.sequence_number}")
    end

    {:ok, events} = SessionStore.get_events(composite, session.id)
    IO.puts("   Total events: #{length(events)}")

    # 5. Use artifact operations (delegated to FileStore)
    IO.puts("\n5. Artifact operations (-> File)")

    :ok = ArtifactStore.put(composite, "snapshot-#{session.id}", "workspace state data")
    {:ok, data} = ArtifactStore.get(composite, "snapshot-#{session.id}")
    IO.puts("   Artifact stored and retrieved: #{byte_size(data)} bytes")

    :ok = ArtifactStore.put(composite, "patch-001", "diff --git a/main.ex...")
    {:ok, patch} = ArtifactStore.get(composite, "patch-001")
    IO.puts("   Patch stored: #{String.slice(patch, 0, 30)}...")

    # 6. Clean up
    IO.puts("\n6. Cleaning up")
    :ok = ArtifactStore.delete(composite, "snapshot-#{session.id}")
    :ok = ArtifactStore.delete(composite, "patch-001")
    :ok = SessionStore.delete_session(composite, session.id)
    {:ok, []} = SessionStore.list_sessions(composite)
    IO.puts("   All cleaned up")

    GenServer.stop(composite)
    GenServer.stop(session_store)
    GenServer.stop(file_store)
    if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
    :ok
  end

  defp configure_repo do
    Application.put_env(:agent_session_manager, DemoRepo,
      database: @db_path,
      pool_size: 1
    )
  end

  defp ensure_migrations do
    :ok = run_migration(1, Migration)
  end

  defp run_migration(version, migration) do
    case Ecto.Migrator.up(DemoRepo, version, migration, log: false) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end
  end

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
    File.rm_rf(@artifact_root)
  end
end

CompositeStoreLive.main(System.argv())
