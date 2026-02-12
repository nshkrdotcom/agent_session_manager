#!/usr/bin/env elixir

# Requires PostgreSQL running locally with database "asm_ash_example".
# Create it with: createdb asm_ash_example
#
# This example is optional and disabled by default in run-all flows.
# Enable explicitly with:
#   ASM_RUN_ASH_EXAMPLE=1 mix run examples/ash_session_store.exs

if System.get_env("ASM_RUN_ASH_EXAMPLE") not in ["1", "true", "TRUE"] do
  IO.puts("Skipping: set ASM_RUN_ASH_EXAMPLE=1 to run Ash SessionStore example")
  System.halt(0)
end

if not Code.ensure_loaded?(Ash.Resource) or not Code.ensure_loaded?(Postgrex) do
  IO.puts("Skipping: ash/ash_postgres/postgrex dependencies not installed")
  System.halt(0)
end

defmodule AshExample.Repo do
  use AshPostgres.Repo,
    otp_app: :agent_session_manager,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule AshExample.AgentSessions do
  use Ash.Domain

  resources do
    resource(AgentSessionManager.Ash.Resources.Session)
    resource(AgentSessionManager.Ash.Resources.Run)
    resource(AgentSessionManager.Ash.Resources.Event)
    resource(AgentSessionManager.Ash.Resources.SessionSequence)
    resource(AgentSessionManager.Ash.Resources.Artifact)
  end
end

defmodule AshExample do
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Ash.Adapters.{AshMaintenance, AshQueryAPI, AshSessionStore}
  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Persistence.RetentionPolicy
  alias AgentSessionManager.Ports.{Maintenance, QueryAPI, SessionStore}

  @repo AshExample.Repo

  def main(_args) do
    IO.puts("\n=== Ash SessionStore Example ===\n")

    repo_config = [
      database: "asm_ash_example",
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      pool_size: 5
    ]

    case ensure_database_ready(repo_config) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts("Skipping: PostgreSQL is not ready (#{format_reason(reason)})")
        System.halt(0)
    end

    Application.put_env(:agent_session_manager, @repo, repo_config)

    Application.put_env(:agent_session_manager, :ash_repo, @repo)

    {:ok, _} = @repo.start_link()

    Ecto.Migrator.up(@repo, 1, Migration, log: false)

    store = {AshSessionStore, AshExample.AgentSessions}
    query = {AshQueryAPI, AshExample.AgentSessions}
    maint = {AshMaintenance, AshExample.AgentSessions}

    IO.puts("1. Creating session")
    {:ok, session} = Session.new(%{agent_id: "ash-agent"})
    :ok = SessionStore.save_session(store, session)
    IO.puts("   Session #{session.id} saved")

    IO.puts("\n2. Creating run")
    {:ok, run} = Run.new(%{session_id: session.id, provider: "claude"})
    {:ok, run} = Run.update_status(run, :running)
    :ok = SessionStore.save_run(store, run)
    IO.puts("   Run #{run.id} saved")

    IO.puts("\n3. Appending events")
    {:ok, e1} = Event.new(%{type: :run_started, session_id: session.id, run_id: run.id})
    {:ok, e2} = Event.new(%{type: :message_received, session_id: session.id, run_id: run.id})
    {:ok, e3} = Event.new(%{type: :run_completed, session_id: session.id, run_id: run.id})
    {:ok, stored} = SessionStore.append_events(store, [e1, e2, e3])

    IO.puts(
      "   Appended #{length(stored)} events with sequences: #{inspect(Enum.map(stored, & &1.sequence_number))}"
    )

    IO.puts("\n4. Querying events")
    {:ok, events} = SessionStore.get_events(store, session.id)
    IO.puts("   Found #{length(events)} events")

    IO.puts("\n5. QueryAPI search")

    {:ok, %{sessions: _sessions, total_count: count}} =
      QueryAPI.search_sessions(query, agent_id: "ash-agent")

    IO.puts("   Found #{count} sessions for ash-agent")

    IO.puts("\n6. Session stats")
    {:ok, stats} = QueryAPI.get_session_stats(query, session.id)
    IO.puts("   Events: #{stats.event_count}, Runs: #{stats.run_count}")

    IO.puts("\n7. Health check")
    {:ok, issues} = Maintenance.health_check(maint)
    IO.puts("   Issues: #{if issues == [], do: "none (healthy)", else: inspect(issues)}")

    IO.puts("\n8. Maintenance execute")
    policy = RetentionPolicy.new(max_completed_session_age_days: 365)
    {:ok, report} = Maintenance.execute(maint, policy)
    IO.puts("   Maintenance duration: #{report.duration_ms}ms")

    IO.puts("\n9. Cleanup")
    :ok = SessionStore.delete_session(store, session.id)
    IO.puts("   Session deleted (cascade)")

    IO.puts("\nAll checks passed!")
  end

  defp ensure_database_ready(config) do
    connect_opts =
      config
      |> Keyword.take([:hostname, :username, :password, :database])
      |> Keyword.merge(timeout: 5000, backoff_type: :stop)

    case Postgrex.start_link(connect_opts) do
      {:ok, pid} ->
        GenServer.stop(pid, :normal)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_reason(%{postgres: %{message: message}}), do: message
  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason), do: inspect(reason)
end

AshExample.main(System.argv())
