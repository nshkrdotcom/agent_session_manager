#!/usr/bin/env elixir
# Session Server Subscription Example (Feature 6)
#
# Demonstrates store-backed subscriptions:
#   {:session_event, session_id, %Core.Event{}}
#
# Usage:
#   mix run examples/session_subscription.exs --provider claude
#   mix run examples/session_subscription.exs --provider codex
#   mix run examples/session_subscription.exs --provider amp

defmodule SessionSubscriptionExample do
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

  @prompts [
    "In one sentence: what is OTP?",
    "In one sentence: what is a GenServer?"
  ]

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Session Subscriptions (#{provider}) ===")
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

      Usage: mix run examples/session_subscription.exs [options]

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
               agent_id: "session-subscription-#{provider}",
               context: %{system_prompt: "Be concise."},
               tags: ["example", "runtime", "subscription"]
             },
             max_concurrent_runs: 1
           ) do
      parent = self()
      listener = spawn_link(fn -> listen(server, parent) end)

      receive do
        {:listener_ready, started_ref, completed_ref} ->
          run_ids =
            @prompts
            |> Enum.map(fn prompt ->
              {:ok, run_id} =
                SessionServer.submit_run(server, %{
                  messages: [%{role: "user", content: prompt}]
                })

              run_id
            end)

          Enum.each(run_ids, fn run_id ->
            _ = SessionServer.await_run(server, run_id, 180_000)
          end)

          :ok = SessionServer.unsubscribe(server, started_ref)
          :ok = SessionServer.unsubscribe(server, completed_ref)
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

  defp listen(server, parent) do
    # Subscribe with type filters to keep output readable.
    {:ok, started_ref} = SessionServer.subscribe(server, from_sequence: 0, type: :run_started)
    {:ok, completed_ref} = SessionServer.subscribe(server, from_sequence: 0, type: :run_completed)
    send(parent, {:listener_ready, started_ref, completed_ref})

    loop()
  end

  defp loop do
    receive do
      {:session_event, _session_id, event} ->
        seq = event.sequence_number
        IO.puts("event seq=#{seq} type=#{event.type} run_id=#{event.run_id}")
        loop()
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
end

SessionSubscriptionExample.main(System.argv())
