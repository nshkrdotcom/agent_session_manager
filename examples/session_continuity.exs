defmodule SessionContinuityExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.{Error, TranscriptBuilder}
  alias AgentSessionManager.SessionManager

  @token "continuity-token-7f3"
  @first_prompt "Remember this token for the next turn: continuity-token-7f3. Reply exactly: remembered."
  @second_prompt "What token did I ask you to remember in the previous turn? Reply with only the token."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Session Continuity Example (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nSession continuity example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nSession continuity example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, session} <- start_session(store, adapter, provider),
         {:ok, first_result} <- execute_turn(store, adapter, session.id, @first_prompt, []),
         {:ok, transcript_before_second} <-
           TranscriptBuilder.from_store(store, session.id, max_messages: 20),
         {:ok, second_result} <-
           execute_turn(store, adapter, session.id, @second_prompt,
             continuation: true,
             continuation_opts: [max_messages: 20]
           ),
         :ok <- assert_transcript_contains_token(transcript_before_second, @token),
         :ok <- assert_second_turn_output(second_result.output, @token) do
      IO.puts("Run 1 output:")
      IO.puts("  #{compact_output(first_result.output)}")

      IO.puts("\nTranscript reconstructed before run 2:")
      IO.puts("  messages: #{length(transcript_before_second.messages)}")
      IO.puts("  last_sequence: #{inspect(transcript_before_second.last_sequence)}")

      preview =
        transcript_before_second.messages
        |> Enum.take(-4)
        |> Enum.map(&format_transcript_message/1)

      Enum.each(preview, fn line -> IO.puts("  #{line}") end)

      IO.puts("\nRun 2 executed with continuation=true")
      IO.puts("Run 2 output:")
      IO.puts("  #{compact_output(second_result.output)}")

      :ok
    end
  end

  defp assert_transcript_contains_token(transcript, token) do
    token_downcase = String.downcase(token)

    contains_token? =
      transcript.messages
      |> Enum.any?(fn message ->
        content = (message[:content] || "") |> to_string() |> String.downcase()
        String.contains?(content, token_downcase)
      end)

    if contains_token? do
      :ok
    else
      {:error, Error.new(:internal_error, "transcript did not retain prior user token content")}
    end
  end

  defp assert_second_turn_output(output, token) do
    text = compact_output(output)
    text_downcase = String.downcase(text)
    token_downcase = String.downcase(token)

    cond do
      String.contains?(text_downcase, token_downcase) ->
        :ok

      contains_missing_context_phrase?(text_downcase) ->
        {:error,
         Error.new(
           :internal_error,
           "provider response indicates missing continuity context: #{text}"
         )}

      true ->
        :ok
    end
  end

  defp contains_missing_context_phrase?(text) do
    phrases = [
      "don't have any record",
      "do not have any record",
      "first message in our conversation",
      "start of our conversation",
      "starts fresh",
      "no previous turn",
      "no prior turn",
      "don't have any context",
      "do not have any context"
    ]

    Enum.any?(phrases, &String.contains?(text, &1))
  end

  defp start_session(store, adapter, provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "continuity-#{provider}",
             context: %{system_prompt: "You are concise and follow instructions exactly."},
             tags: ["example", "continuity", provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp execute_turn(store, adapter, session_id, prompt, opts) do
    with {:ok, run} <-
           SessionManager.start_run(store, adapter, session_id, %{
             messages: [%{role: "user", content: prompt}]
           }),
         {:ok, result} <- SessionManager.execute_run(store, adapter, run.id, opts) do
      {:ok, result}
    end
  end

  defp compact_output(%{content: content}) when is_binary(content), do: String.trim(content)
  defp compact_output(output), do: inspect(output)

  defp format_transcript_message(%{role: role, content: content}) when is_binary(content) do
    "#{role}: #{content}"
  end

  defp format_transcript_message(%{
         role: :assistant,
         tool_name: tool_name,
         tool_call_id: tool_call_id
       })
       when is_binary(tool_name) do
    "assistant tool call #{tool_name} (#{tool_call_id || "unknown"})"
  end

  defp format_transcript_message(%{role: :tool, tool_name: tool_name, tool_call_id: tool_call_id})
       when is_binary(tool_name) do
    "tool result #{tool_name} (#{tool_call_id || "unknown"})"
  end

  defp format_transcript_message(message) do
    inspect(message)
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

  defp start_adapter(provider) do
    {:error, Error.new(:validation_error, "unknown provider: #{provider}")}
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

    Usage: mix run examples/session_continuity.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/session_continuity.exs --provider claude
      mix run examples/session_continuity.exs --provider codex
      mix run examples/session_continuity.exs --provider amp
    """)
  end
end

SessionContinuityExample.main(System.argv())
