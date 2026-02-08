#!/usr/bin/env elixir

defmodule CursorPagination do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @prompts [
    "State one practical benefit of OTP supervision in one sentence.",
    "State one practical benefit of BEAM preemption in one sentence."
  ]

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Cursor Pagination (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nCursor pagination example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nCursor pagination example failed: #{inspect(reason)}")
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

    Usage: mix run examples/cursor_pagination.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/cursor_pagination.exs --provider claude
      mix run examples/cursor_pagination.exs --provider codex
      mix run examples/cursor_pagination.exs --provider amp
    """)
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, session} <- start_session(store, adapter, provider),
         {:ok, run_ids} <- execute_runs(store, adapter, session.id),
         {:ok, events} <- SessionStore.get_events(store, session.id),
         :ok <- assert_sequential(events) do
      sequence_numbers = Enum.map(events, & &1.sequence_number)
      latest_sequence = List.last(sequence_numbers)

      {:ok, page_1} = SessionStore.get_events(store, session.id, limit: 4)
      page_1_last = List.last(page_1).sequence_number

      {:ok, page_2} = SessionStore.get_events(store, session.id, after: page_1_last, limit: 4)

      {:ok, bounded} =
        SessionStore.get_events(store, session.id,
          after: max(latest_sequence - 4, 0),
          before: latest_sequence
        )

      {:ok, first_run_events} =
        SessionStore.get_events(store, session.id, run_id: hd(run_ids), after: 0, limit: 10)

      {:ok, latest} = SessionStore.get_latest_sequence(store, session.id)

      if latest != latest_sequence do
        raise "Expected latest sequence #{latest_sequence}, got #{latest}"
      end

      if page_2 != [] do
        if hd(page_2).sequence_number <= page_1_last do
          raise "Expected page_2 to start after cursor #{page_1_last}"
        end
      end

      if Enum.any?(first_run_events, &(&1.run_id != hd(run_ids))) do
        raise "Expected run_id filtered page to contain only run #{hd(run_ids)} events"
      end

      print_page("Page 1", page_1)
      print_page("Page 2", page_2)
      print_page("Bounded Window", bounded)
      print_page("Run-Scoped Window", first_run_events)

      IO.puts("\nTotal events: #{length(events)}")
      IO.puts("Latest sequence: #{latest}")

      :ok
    end
  end

  defp start_session(store, adapter, provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "cursor-pagination-#{provider}",
             context: %{system_prompt: "You are concise and technical."},
             tags: ["example", "cursor-pagination", provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp execute_runs(store, adapter, session_id) do
    result =
      @prompts
      |> Enum.reduce_while([], fn prompt, acc ->
        with {:ok, run} <-
               SessionManager.start_run(store, adapter, session_id, %{
                 messages: [%{role: "user", content: prompt}]
               }),
             {:ok, _result} <- SessionManager.execute_run(store, adapter, run.id) do
          {:cont, [run.id | acc]}
        else
          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, _reason} = error -> error
      run_ids -> {:ok, Enum.reverse(run_ids)}
    end
  end

  defp assert_sequential(events) do
    sequence_numbers = Enum.map(events, & &1.sequence_number)
    expected = Enum.to_list(1..length(events))

    if sequence_numbers == expected do
      :ok
    else
      {:error,
       %{
         message: "Persisted sequence numbers are not strictly sequential",
         sequence_numbers: sequence_numbers,
         expected: expected
       }}
    end
  end

  defp print_page(title, events) do
    IO.puts("\n#{title}")

    Enum.each(events, fn event ->
      IO.puts("  seq=#{event.sequence_number} type=#{event.type} run_id=#{event.run_id || "-"}")
    end)
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

CursorPagination.main(System.argv())
