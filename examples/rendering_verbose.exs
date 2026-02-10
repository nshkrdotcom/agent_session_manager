defmodule RenderingVerbose do
  @moduledoc false

  # Runs a real provider session and renders the event stream using
  # VerboseRenderer with bracketed line-by-line output to the terminal.
  #
  # Demonstrates:
  #   - VerboseRenderer format ([run_started], [tool_call_started], etc.)
  #   - Inline text streaming with automatic line breaks before structured events
  #   - Token usage and stop reason display
  #   - TTYSink terminal output

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter
  }

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.VerboseRenderer
  alias AgentSessionManager.Rendering.Sinks.TTYSink
  alias AgentSessionManager.StreamSession

  @prompt "Write an Elixir function that calculates the nth Fibonacci number. Keep your response brief."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    {provider, color} = parse_args(args)

    IO.puts("")
    IO.puts("=== VerboseRenderer (#{provider}) ===")
    IO.puts("")

    case run(provider, color) do
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
  # Argument Parsing
  # ============================================================================

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, help: :boolean, no_color: :boolean],
        aliases: [p: :provider, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"
    color = !opts[:no_color]

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    {provider, color}
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/rendering_verbose.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/rendering_verbose.exs --provider claude
      mix run examples/rendering_verbose.exs --provider codex
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider, color) do
    IO.puts("Prompt: #{@prompt}")
    IO.puts("")

    case StreamSession.start(
           adapter: adapter_spec(provider),
           input: %{messages: [%{role: "user", content: @prompt}]}
         ) do
      {:ok, stream, close_fun, _meta} ->
        Rendering.stream(stream,
          renderer: {VerboseRenderer, [color: color]},
          sinks: [{TTYSink, []}]
        )

        close_fun.()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adapter_spec("claude"), do: {ClaudeAdapter, []}
  defp adapter_spec("codex"), do: {CodexAdapter, working_directory: File.cwd!()}
  defp adapter_spec("amp"), do: {AmpAdapter, cwd: File.cwd!()}
end

RenderingVerbose.main(System.argv())
