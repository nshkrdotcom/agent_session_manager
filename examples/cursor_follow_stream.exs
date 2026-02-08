#!/usr/bin/env elixir

defmodule CursorFollowStream do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @prompt "Reply with a short sentence that includes the word cursor."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Cursor Follow Stream (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nCursor follow stream example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nCursor follow stream example failed: #{inspect(reason)}")
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

    Usage: mix run examples/cursor_follow_stream.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/cursor_follow_stream.exs --provider claude
      mix run examples/cursor_follow_stream.exs --provider codex
      mix run examples/cursor_follow_stream.exs --provider amp
    """)
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, session} <- start_session(store, adapter, provider),
         {:ok, run} <- start_run(store, adapter, session.id),
         {:ok, cursor} <- SessionStore.get_latest_sequence(store, session.id),
         stream_task <- stream_after_cursor(store, session.id, cursor),
         {:ok, _result} <- SessionManager.execute_run(store, adapter, run.id),
         {:ok, streamed_events} <- await_stream(stream_task),
         :ok <- assert_streamed_events(streamed_events, cursor) do
      IO.puts("Start cursor: #{cursor}")
      IO.puts("Streamed events:")

      Enum.each(streamed_events, fn event ->
        IO.puts("  seq=#{event.sequence_number} type=#{event.type} run_id=#{event.run_id || "-"}")
      end)

      :ok
    end
  end

  defp start_session(store, adapter, provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "cursor-follow-#{provider}",
             context: %{system_prompt: "You are concise and technical."},
             tags: ["example", "cursor-follow", provider]
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

  defp stream_after_cursor(store, session_id, cursor) do
    Task.async(fn ->
      SessionManager.stream_session_events(store, session_id,
        after: cursor,
        limit: 10,
        poll_interval_ms: 20
      )
      |> Enum.take(2)
    end)
  end

  defp await_stream(task) do
    case Task.await(task, 120_000) do
      events when is_list(events) -> {:ok, events}
      other -> {:error, {:unexpected_stream_result, other}}
    end
  end

  defp assert_streamed_events(events, cursor) do
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

CursorFollowStream.main(System.argv())
