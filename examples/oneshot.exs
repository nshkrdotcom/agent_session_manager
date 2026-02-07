defmodule Oneshot do
  @moduledoc false

  # Simplest possible example: one-shot execution using SessionManager.run_once/4.
  #
  # This collapses the full session lifecycle (create, activate, run, execute,
  # complete/fail) into a single function call.

  alias AgentSessionManager.Adapters.{ClaudeAdapter, CodexAdapter, InMemorySessionStore}
  alias AgentSessionManager.SessionManager

  @prompt "What is the BEAM virtual machine? Keep your answer to two sentences."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== One-Shot Execution (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("")
        IO.puts("Done.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # ============================================================================
  # Command Line Argument Parsing
  # ============================================================================

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

    unless provider in ["claude", "codex"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/oneshot.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude or codex). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY

    Examples:
      mix run examples/oneshot.exs --provider claude
      mix run examples/oneshot.exs --provider codex
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider) do
      IO.puts("Prompt: #{@prompt}")
      IO.puts("")

      event_callback = fn event ->
        case event.type do
          :message_streamed ->
            content = event.data[:delta] || event.data[:content] || ""
            IO.write(content)

          :run_started ->
            IO.puts("Streaming...\n")

          :run_completed ->
            IO.puts("\n")

          _ ->
            :ok
        end
      end

      case SessionManager.run_once(
             store,
             adapter,
             %{
               messages: [%{role: "user", content: @prompt}]
             },
             context: %{system_prompt: "You are a concise technical assistant."},
             event_callback: event_callback
           ) do
        {:ok, result} ->
          IO.puts("Response: #{inspect(result.output)}")
          IO.puts("Tokens:   #{inspect(result.token_usage)}")
          IO.puts("Session:  #{result.session_id}")
          IO.puts("Run:      #{result.run_id}")
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp start_adapter("claude") do
    ClaudeAdapter.start_link([])
  end

  defp start_adapter("codex") do
    CodexAdapter.start_link(working_directory: File.cwd!())
  end
end

Oneshot.main(System.argv())
