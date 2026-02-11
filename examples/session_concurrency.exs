#!/usr/bin/env elixir
# Session Server Multi-Slot Concurrency Example (Feature 6 v2)
#
# Demonstrates parallel execution bounded by max_concurrent_runs slots.
# Submits N runs and shows that up to max_concurrent_runs execute in
# parallel, with the remainder queued and drained as slots free up.
#
# Usage:
#   mix run examples/session_concurrency.exs --provider claude
#   mix run examples/session_concurrency.exs --provider codex
#   mix run examples/session_concurrency.exs --provider amp

defmodule SessionConcurrencyExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Models
  alias AgentSessionManager.Runtime.SessionServer

  @slots 2
  @total_runs 4

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Session Concurrency (#{provider}, #{@slots} slots, #{@total_runs} runs) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nDone.")
        System.halt(0)

      {:error, error} ->
        IO.puts(:stderr, "\nError: #{inspect(error)}")
        System.halt(1)
    end
  end

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, help: :boolean],
        aliases: [p: :provider, h: :help]
      )

    if opts[:help] do
      IO.puts("""

      Usage: mix run examples/session_concurrency.exs [options]

      Options:
        --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
        --help, -h             Show this help message
      """)

      System.halt(0)
    end

    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      System.halt(1)
    end

    provider
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, server} <-
           SessionServer.start_link(
             store: store,
             adapter: adapter,
             session_opts: %{
               agent_id: "session-concurrency-#{provider}",
               context: %{system_prompt: "Follow instructions precisely."},
               tags: ["example", "runtime", "concurrency"]
             },
             max_concurrent_runs: @slots,
             # Uses the Config default (100); override with max_queued_runs: N
             max_queued_runs: AgentSessionManager.Config.get(:max_queued_runs)
           ) do
      IO.puts("Server started with max_concurrent_runs=#{@slots}")
      IO.puts("")

      # Submit all runs
      run_ids =
        for i <- 1..@total_runs do
          {:ok, run_id} =
            SessionServer.submit_run(server, %{
              messages: [
                %{role: "user", content: "Say 'run #{i} done' and nothing else."}
              ]
            })

          IO.puts("Submitted run #{i}: #{run_id}")
          run_id
        end

      IO.puts("")

      # Check status to show parallelism
      Process.sleep(500)
      status = SessionServer.status(server)
      IO.puts("Status after submit:")
      IO.puts("  in_flight: #{status.in_flight_count}")
      IO.puts("  queued:    #{status.queued_count}")
      IO.puts("")

      # Await all runs
      IO.puts("Awaiting all runs...\n")

      Enum.each(run_ids, fn run_id ->
        case SessionServer.await_run(server, run_id, 180_000) do
          {:ok, result} ->
            IO.puts("Completed #{run_id}: #{compact(result.output)}")

          {:error, error} ->
            IO.puts("Failed #{run_id}: #{inspect(error)}")
        end
      end)

      # Drain and show final status
      :ok = SessionServer.drain(server, 5_000)
      final_status = SessionServer.status(server)

      IO.puts("")
      IO.puts("Final status:")
      IO.puts("  in_flight: #{final_status.in_flight_count}")
      IO.puts("  queued:    #{final_status.queued_count}")

      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:internal_error, inspect(reason))}
    end
  end

  defp start_adapter("claude") do
    ClaudeAdapter.start_link(model: Models.default_model(:claude), tools: [])
  end

  defp start_adapter("codex") do
    CodexAdapter.start_link(working_directory: File.cwd!())
  end

  defp start_adapter("amp") do
    AmpAdapter.start_link(cwd: File.cwd!())
  end

  defp compact(output) when is_binary(output), do: String.slice(output, 0, 120)

  defp compact(output) when is_map(output) do
    output
    |> inspect(pretty: false, limit: 8)
    |> String.slice(0, 160)
  end

  defp compact(other), do: inspect(other, limit: 8)
end

SessionConcurrencyExample.main(System.argv())
