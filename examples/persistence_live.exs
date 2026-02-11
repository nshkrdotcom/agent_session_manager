#!/usr/bin/env elixir
# Persistence Live Example
#
# Demonstrates end-to-end persistence with a real provider SDK.
# Events flow through EventPipeline into EctoSessionStore (SQLite).
#
# Usage:
#   mix run examples/persistence_live.exs --provider claude
#   mix run examples/persistence_live.exs --provider codex
#   mix run examples/persistence_live.exs --provider amp

defmodule PersistenceLive.DemoRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :agent_session_manager,
    adapter: Ecto.Adapters.SQLite3
end

defmodule PersistenceLive do
  @moduledoc false

  alias AgentSessionManager.Adapters.{ClaudeAdapter, CodexAdapter, AmpAdapter, EctoSessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV2
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Models
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @db_path "/tmp/asm_persistence_live_demo.db"
  @repo PersistenceLive.DemoRepo

  def main(args) do
    IO.puts("\n=== Persistence Live Example ===\n")

    provider = parse_provider(args)
    IO.puts("Provider: #{provider}\n")

    cleanup()

    case run(provider) do
      :ok ->
        IO.puts("\nAll checks passed!")
        cleanup()
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{format_error(reason)}")
        cleanup()
        System.halt(1)
    end
  end

  defp run(provider) do
    # 1. Start Ecto Repo + store
    IO.puts("1. Starting Ecto Repo and SessionStore")
    Application.put_env(:agent_session_manager, @repo, database: @db_path, pool_size: 1)
    {:ok, _} = @repo.start_link()
    Ecto.Migrator.up(@repo, 1, Migration, log: false)
    Ecto.Migrator.up(@repo, 2, MigrationV2, log: false)
    {:ok, store} = EctoSessionStore.start_link(repo: @repo)
    IO.puts("   Store started (SQLite: #{@db_path})")

    # 2. Start the provider adapter
    IO.puts("\n2. Starting #{provider} adapter")

    case start_adapter(provider) do
      {:ok, adapter} ->
        IO.puts("   Adapter started")
        run_with_adapter(store, adapter, provider)

      {:error, error} ->
        IO.puts("   #{format_error(error)}")
        {:error, error}
    end
  end

  defp run_with_adapter(store, adapter, provider) do
    # 3. Execute via SessionManager.run_once (events flow through EventPipeline)
    IO.puts("\n3. Running SessionManager.run_once (events persist via EventPipeline)")
    IO.puts("   Prompt: \"Say hello in one sentence.\"")

    streamed_chunks = []
    chunk_ref = make_ref()
    parent = self()

    event_callback = fn event_data ->
      case event_data[:type] do
        :message_streamed ->
          delta = get_in(event_data, [:data, :delta]) || ""
          send(parent, {chunk_ref, delta})

        type ->
          IO.puts("   [event] #{type} (seq=#{event_data[:sequence_number] || "?"})")
      end
    end

    task =
      Task.async(fn ->
        SessionManager.run_once(
          store,
          adapter,
          %{
            messages: [%{role: "user", content: "Say hello in one sentence."}]
          },
          event_callback: event_callback,
          agent_id: "persistence-live-#{provider}",
          tags: ["persistence", "live"]
        )
      end)

    # Collect streamed output
    IO.puts("\n   Response:")
    IO.write("   ")
    streamed_chunks = collect_stream(chunk_ref, streamed_chunks)
    IO.puts("\n")

    case Task.await(task, 120_000) do
      {:ok, result} ->
        IO.puts("   Run completed successfully")
        print_result(result)
        verify_persistence(store, provider)

      {:error, error} ->
        {:error, error}
    end
  end

  defp verify_persistence(store, provider) do
    # 4. Query persisted data
    IO.puts("\n4. Verifying persisted data")

    {:ok, sessions} = SessionStore.list_sessions(store)
    session = List.first(sessions)
    IO.puts("   Sessions: #{length(sessions)}")
    IO.puts("   Session ID: #{session.id}")
    IO.puts("   Agent ID: #{session.agent_id}")
    IO.puts("   Status: #{session.status}")
    IO.puts("   Tags: #{inspect(session.tags)}")

    # 5. Query persisted events
    IO.puts("\n5. Persisted events")
    {:ok, events} = SessionStore.get_events(store, session.id)
    IO.puts("   Total events: #{length(events)}")

    for event <- events do
      IO.puts(
        "   seq=#{event.sequence_number} type=#{event.type} provider=#{event.provider || "nil"}"
      )
    end

    # 6. Check sequence integrity
    IO.puts("\n6. Sequence integrity")
    {:ok, latest_seq} = SessionStore.get_latest_sequence(store, session.id)
    IO.puts("   Latest sequence: #{latest_seq}")
    IO.puts("   Events stored: #{length(events)}")
    IO.puts("   Match: #{latest_seq == length(events)}")

    # 7. Query persisted runs
    IO.puts("\n7. Persisted runs")
    {:ok, runs} = SessionStore.list_runs(store, session.id)
    IO.puts("   Total runs: #{length(runs)}")

    for run <- runs do
      tokens = run.token_usage || %{}

      IO.puts(
        "   #{run.id}: provider=#{run.provider || provider} status=#{run.status} tokens=#{inspect(tokens)}"
      )
    end

    IO.puts("\n8. Cleaning up")
    GenServer.stop(store)
    :ok
  end

  defp print_result(result) do
    usage = result[:token_usage] || %{}
    input = trunc(usage[:input_tokens] || 0)
    output = trunc(usage[:output_tokens] || 0)
    IO.puts("   Tokens: input=#{input} output=#{output} total=#{input + output}")
  end

  defp collect_stream(ref, chunks) do
    receive do
      {^ref, delta} ->
        IO.write(delta)
        collect_stream(ref, [delta | chunks])
    after
      100 -> chunks
    end
  end

  defp start_adapter("claude") do
    case Code.ensure_loaded(ClaudeAdapter) do
      {:module, _} -> ClaudeAdapter.start_link(model: Models.default_model(:claude))
      _ -> {:error, Error.new(:sdk_not_available, "Claude SDK not available")}
    end
  end

  defp start_adapter("codex") do
    case Code.ensure_loaded(CodexAdapter) do
      {:module, _} -> CodexAdapter.start_link(working_directory: File.cwd!())
      _ -> {:error, Error.new(:sdk_not_available, "Codex SDK not available")}
    end
  end

  defp start_adapter("amp") do
    case Code.ensure_loaded(AmpAdapter) do
      {:module, _} -> AmpAdapter.start_link(cwd: File.cwd!())
      _ -> {:error, Error.new(:sdk_not_available, "Amp SDK not available")}
    end
  end

  defp parse_provider(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [provider: :string], aliases: [p: :provider])
    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      System.halt(1)
    end

    provider
  end

  defp format_error(%Error{} = e), do: "#{e.code}: #{e.message}"
  defp format_error(e), do: inspect(e)

  defp cleanup do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")
  end
end

PersistenceLive.main(System.argv())
