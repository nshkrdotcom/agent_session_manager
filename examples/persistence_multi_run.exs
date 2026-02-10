#!/usr/bin/env elixir
# Persistence Multi-Run Example
#
# Demonstrates multiple runs from different providers stored in a single session.
# Uses EctoSessionStore (SQLite) + QueryAPI to show cross-provider aggregation.
#
# This example seeds runs with realistic data for each provider and demonstrates
# the QueryAPI's cross-provider search and usage summary capabilities.
#
# Usage:
#   mix run examples/persistence_multi_run.exs

defmodule PersistenceMultiRun.DemoRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :agent_session_manager,
    adapter: Ecto.Adapters.SQLite3
end

defmodule PersistenceMultiRun do
  @moduledoc false

  alias AgentSessionManager.Adapters.{EctoQueryAPI, EctoSessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV2
  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.{QueryAPI, SessionStore}

  @db_path "/tmp/asm_persistence_multi_run_demo.db"
  @repo PersistenceMultiRun.DemoRepo

  def main(_args) do
    IO.puts("\n=== Persistence Multi-Run Example ===\n")

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
    Ecto.Migrator.up(@repo, 2, MigrationV2, log: false)

    {:ok, store} = EctoSessionStore.start_link(repo: @repo)
    {:ok, query} = EctoQueryAPI.start_link(repo: @repo)
    IO.puts("   All stores started")

    # 2. Create a single session with multiple provider runs
    IO.puts("\n2. Creating session with runs from 3 providers")

    {:ok, session} = Session.new(%{id: "ses_multi", agent_id: "multi-agent"})
    :ok = SessionStore.save_session(store, %{session | status: :completed})

    # Run 1: Claude (code generation)
    create_provider_run(
      store,
      "ses_multi",
      "run_claude_1",
      "claude",
      %{
        input_tokens: 1200,
        output_tokens: 800,
        total_tokens: 2000
      },
      [
        :run_started,
        :message_received,
        :tool_call_started,
        :tool_call_completed,
        :message_received,
        :token_usage_updated,
        :run_completed
      ]
    )

    # Run 2: Codex (code review)
    create_provider_run(
      store,
      "ses_multi",
      "run_codex_1",
      "codex",
      %{
        input_tokens: 800,
        output_tokens: 400,
        total_tokens: 1200
      },
      [
        :run_started,
        :message_received,
        :message_streamed,
        :message_streamed,
        :token_usage_updated,
        :run_completed
      ]
    )

    # Run 3: Amp (refactoring)
    create_provider_run(
      store,
      "ses_multi",
      "run_amp_1",
      "amp",
      %{
        input_tokens: 1500,
        output_tokens: 1200,
        total_tokens: 2700
      },
      [
        :run_started,
        :message_received,
        :tool_call_started,
        :tool_call_completed,
        :tool_call_started,
        :tool_call_completed,
        :message_received,
        :token_usage_updated,
        :run_completed
      ]
    )

    IO.puts("   3 provider runs created")

    # 3. Show session runs
    IO.puts("\n3. Runs in session")
    {:ok, runs} = SessionStore.list_runs(store, "ses_multi")

    for r <- runs do
      tokens = r.token_usage
      IO.puts("   #{r.id}: provider=#{r.provider}, #{tokens.total_tokens} tokens")
    end

    # 4. Show events per run
    IO.puts("\n4. Events by run")
    {:ok, all_events} = SessionStore.get_events(store, "ses_multi")
    events_by_run = Enum.group_by(all_events, & &1.run_id)

    for {run_id, events} <- events_by_run do
      types = Enum.map(events, & &1.type) |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
      IO.puts("   #{run_id}: #{length(events)} events [#{types}]")
    end

    # 5. Cross-provider search
    IO.puts("\n5. Search runs by provider (QueryAPI)")

    for provider <- ["claude", "codex", "amp"] do
      {:ok, %{runs: provider_runs}} = QueryAPI.search_runs(query, provider: provider)
      IO.puts("   #{provider}: #{length(provider_runs)} runs")
    end

    # 6. Usage summary across providers
    IO.puts("\n6. Usage summary (QueryAPI)")
    {:ok, summary} = QueryAPI.get_usage_summary(query)
    IO.puts("   Total runs: #{summary.run_count}")
    IO.puts("   Total tokens: #{summary.total_tokens}")

    IO.puts("\n   Per-provider breakdown:")

    for {provider, stats} <- Enum.sort(summary.by_provider) do
      IO.puts(
        "     #{provider}: #{stats.run_count} runs, #{stats.total_tokens} tokens " <>
          "(in=#{stats.input_tokens}, out=#{stats.output_tokens})"
      )
    end

    # 7. Session stats
    IO.puts("\n7. Session stats (QueryAPI)")
    {:ok, stats} = QueryAPI.get_session_stats(query, "ses_multi")
    IO.puts("   Events: #{stats.event_count}")
    IO.puts("   Runs: #{stats.run_count}")
    IO.puts("   Providers used: #{inspect(stats.providers_used)}")
    IO.puts("   Token totals: #{inspect(stats.token_totals)}")

    # 8. Export session
    IO.puts("\n8. Export session (QueryAPI)")
    {:ok, export} = QueryAPI.export_session(query, "ses_multi")
    IO.puts("   Session: #{export.session.id} (#{export.session.status})")
    IO.puts("   Runs exported: #{length(export.runs)}")
    IO.puts("   Events exported: #{length(export.events)}")

    # 9. Sequence integrity check
    IO.puts("\n9. Sequence integrity")
    {:ok, latest_seq} = SessionStore.get_latest_sequence(store, "ses_multi")
    IO.puts("   Latest sequence: #{latest_seq}")
    IO.puts("   Total events: #{length(all_events)}")
    IO.puts("   All sequences monotonic: #{sequences_monotonic?(all_events)}")

    IO.puts("\n10. Cleaning up")
    GenServer.stop(query)
    GenServer.stop(store)
    :ok
  end

  defp create_provider_run(store, session_id, run_id, provider, token_usage, event_types) do
    {:ok, run} = Run.new(%{id: run_id, session_id: session_id})
    run = %{run | provider: provider, status: :completed, token_usage: token_usage}
    :ok = SessionStore.save_run(store, run)

    for type <- event_types do
      {:ok, event} =
        Event.new(%{
          type: type,
          session_id: session_id,
          run_id: run_id,
          data: %{provider: provider}
        })

      {:ok, _} = SessionStore.append_event_with_sequence(store, event)
    end
  end

  defp sequences_monotonic?(events) do
    events
    |> Enum.map(& &1.sequence_number)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
  end
end

PersistenceMultiRun.main(System.argv())
