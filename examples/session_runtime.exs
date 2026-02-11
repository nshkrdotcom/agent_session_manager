#!/usr/bin/env elixir
# Session Server Runtime Example (Feature 6)
#
# Demonstrates strict sequential (FIFO) runtime execution using SessionServer.
#
# Usage:
#   mix run examples/session_runtime.exs --provider claude
#   mix run examples/session_runtime.exs --provider codex
#   mix run examples/session_runtime.exs --provider amp

defmodule SessionRuntimeExample do
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
    "Say 'run 1 done' and nothing else.",
    "Say 'run 2 done' and nothing else.",
    "Say 'run 3 done' and nothing else."
  ]

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Session Runtime (#{provider}) ===")
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

      Usage: mix run examples/session_runtime.exs [options]

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
               agent_id: "session-runtime-#{provider}",
               context: %{system_prompt: "Follow instructions precisely."},
               tags: ["example", "runtime"]
             },
             max_concurrent_runs: 1,
             max_queued_runs: 100
           ) do
      run_ids =
        @prompts
        |> Enum.with_index(1)
        |> Enum.map(fn {prompt, idx} ->
          {:ok, run_id} =
            SessionServer.submit_run(server, %{
              messages: [%{role: "user", content: prompt}]
            })

          IO.puts("Submitted #{idx}: #{run_id}")
          run_id
        end)

      IO.puts("\nAwaiting completion (strict sequential FIFO)...\n")

      Enum.each(run_ids, fn run_id ->
        case SessionServer.await_run(server, run_id, 120_000) do
          {:ok, result} ->
            IO.puts("Completed #{run_id}: output=#{compact(result.output)}")

          {:error, error} ->
            IO.puts("Completed #{run_id}: error=#{inspect(error)}")
        end
      end)

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

SessionRuntimeExample.main(System.argv())
