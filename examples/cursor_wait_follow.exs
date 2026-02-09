#!/usr/bin/env elixir

defmodule CursorWaitFollow do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @prompt "Reply with exactly one sentence about event-driven architecture."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Cursor Wait Follow (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nCursor wait follow example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nCursor wait follow example failed: #{inspect(reason)}")
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
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/cursor_wait_follow.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/cursor_wait_follow.exs --provider claude
      mix run examples/cursor_wait_follow.exs --provider codex
      mix run examples/cursor_wait_follow.exs --provider amp
    """)
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, session} <- start_session(store, adapter, provider),
         {:ok, run} <- start_run(store, adapter, session.id),
         {:ok, cursor} <- SessionStore.get_latest_sequence(store, session.id) do
      IO.puts("Start cursor: #{cursor}")
      IO.puts("Using wait_timeout_ms=30000 for long-poll (no busy polling)")
      IO.puts("")

      # Start a stream with wait_timeout_ms — the store blocks until events arrive
      # instead of repeatedly sleeping and polling
      stream_task = stream_with_wait(store, session.id, cursor)

      # Execute a run — this produces events that unblock the waiting stream
      {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)

      case await_stream(stream_task) do
        {:ok, streamed_events} ->
          verify_and_print(streamed_events, cursor)

        error ->
          error
      end
    end
  end

  defp start_session(store, adapter, provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "cursor-wait-follow-#{provider}",
             context: %{system_prompt: "You are concise and technical."},
             tags: ["example", "cursor-wait-follow", provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp start_run(store, adapter, session_id) do
    SessionManager.start_run(store, adapter, session_id, %{
      messages: [%{role: "user", content: @prompt}]
    })
  end

  defp stream_with_wait(store, session_id, cursor) do
    Task.async(fn ->
      SessionManager.stream_session_events(store, session_id,
        after: cursor,
        limit: 10,
        wait_timeout_ms: 30_000
      )
      |> Enum.take(3)
    end)
  end

  defp await_stream(task) do
    case Task.await(task, 120_000) do
      events when is_list(events) -> {:ok, events}
      other -> {:error, {:unexpected_stream_result, other}}
    end
  end

  defp verify_and_print(events, cursor) do
    if events == [] do
      {:error, :no_events_streamed}
    else
      sequence_numbers = Enum.map(events, & &1.sequence_number)
      sorted = Enum.sort(sequence_numbers)

      cond do
        sequence_numbers != sorted ->
          {:error, {:non_monotonic_sequences, sequence_numbers}}

        Enum.any?(sequence_numbers, &(&1 <= cursor)) ->
          {:error, {:events_not_after_cursor, cursor, sequence_numbers}}

        true ->
          IO.puts("Streamed events (via wait_timeout_ms long-poll):")

          Enum.each(events, fn event ->
            metadata_str =
              if map_size(event.metadata) > 0 do
                " metadata=#{inspect(event.metadata)}"
              else
                ""
              end

            IO.puts(
              "  seq=#{event.sequence_number} type=#{event.type} " <>
                "run_id=#{event.run_id || "-"} ts=#{event.timestamp}#{metadata_str}"
            )
          end)

          # Verify adapter events have provider metadata
          adapter_events =
            Enum.filter(events, fn e ->
              e.type in [:run_started, :message_received, :run_completed, :message_streamed]
            end)

          if adapter_events != [] do
            IO.puts("\nAdapter event metadata verification:")

            Enum.each(adapter_events, fn event ->
              provider = event.metadata[:provider]
              IO.puts("  #{event.type}: provider=#{provider || "n/a"}")
            end)
          end

          IO.puts("\nResume cursor: #{List.last(sequence_numbers)}")

          :ok
      end
    end
  end

  defp start_adapter("claude") do
    ClaudeAdapter.start_link([])
  end

  defp start_adapter("codex") do
    CodexAdapter.start_link(working_directory: File.cwd!())
  end

  defp start_adapter("amp") do
    AmpAdapter.start_link(cwd: File.cwd!())
  end
end

CursorWaitFollow.main(System.argv())
