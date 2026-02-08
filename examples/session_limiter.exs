#!/usr/bin/env elixir
# Session Server Limiter Example (Feature 6)
#
# Demonstrates ConcurrencyLimiter acquire/release around SessionServer execution.
#
# Usage:
#   mix run examples/session_limiter.exs --provider claude
#   mix run examples/session_limiter.exs --provider codex
#   mix run examples/session_limiter.exs --provider amp

defmodule SessionLimiterExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Concurrency.ConcurrencyLimiter
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Runtime.SessionServer

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Session Limiter (#{provider}) ===")
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

      Usage: mix run examples/session_limiter.exs [options]

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
         {:ok, limiter} <-
           ConcurrencyLimiter.start_link(
             max_parallel_sessions: 100,
             max_parallel_runs: 1
           ),
         {:ok, server} <-
           SessionServer.start_link(
             store: store,
             adapter: adapter,
             limiter: limiter,
             session_opts: %{
               agent_id: "session-limiter-#{provider}",
               context: %{system_prompt: "Be concise."},
               tags: ["example", "runtime", "limiter"]
             },
             max_concurrent_runs: 1
           ) do
      parent = self()

      listener =
        spawn_link(fn ->
          {:ok, ref} = SessionServer.subscribe(server, from_sequence: 0, type: :run_started)
          send(parent, {:listener_ready, ref})

          receive do
            {:session_event, _session_id, event} ->
              send(parent, {:run_started, event.run_id})
          end
        end)

      receive do
        {:listener_ready, ref} ->
          {:ok, run_id} =
            SessionServer.submit_run(server, %{
              messages: [%{role: "user", content: "Say 'limiter run 1 done' and nothing else."}]
            })

          {:ok, run_id2} =
            SessionServer.submit_run(server, %{
              messages: [%{role: "user", content: "Say 'limiter run 2 done' and nothing else."}]
            })

          receive do
            {:run_started, ^run_id} ->
              IO.puts(
                "Limiter status after run start: #{inspect(ConcurrencyLimiter.get_status(limiter))}"
              )
          after
            30_000 ->
              IO.puts("Did not observe run_started event in time")
          end

          _ = SessionServer.await_run(server, run_id, 180_000)
          _ = SessionServer.await_run(server, run_id2, 180_000)

          IO.puts(
            "Limiter status after completion: #{inspect(ConcurrencyLimiter.get_status(limiter))}"
          )

          :ok = SessionServer.unsubscribe(server, ref)
          Process.exit(listener, :normal)
          :ok
      after
        5_000 ->
          {:error, Error.new(:timeout, "Listener did not start")}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:internal_error, inspect(reason))}
    end
  end

  defp start_adapter("claude") do
    ClaudeAdapter.start_link(model: "claude-haiku-4-5-20251001", tools: [])
  end

  defp start_adapter("codex") do
    CodexAdapter.start_link(working_directory: File.cwd!())
  end

  defp start_adapter("amp") do
    AmpAdapter.start_link(cwd: File.cwd!())
  end
end

SessionLimiterExample.main(System.argv())
