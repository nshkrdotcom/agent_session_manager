defmodule RenderingCompact do
  @moduledoc false

  # Runs a real provider session and renders the event stream using
  # CompactRenderer with colored token output to the terminal.
  #
  # Demonstrates:
  #   - Bridging SessionManager event callbacks into a lazy Stream
  #   - CompactRenderer token format (r+, r-, t+, t-, >>, tk:, msg)
  #   - Color toggle via --no-color flag
  #   - TTYSink terminal output

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter
  }

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.CompactRenderer
  alias AgentSessionManager.Rendering.Sinks.TTYSink
  alias AgentSessionManager.StreamSession

  @prompt "List three Elixir OTP behaviours and describe each in one sentence."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    {provider, opts} = parse_args(args)

    IO.puts("")
    IO.puts("=== CompactRenderer (#{provider}) ===")
    IO.puts("")

    case run(provider, opts) do
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
        strict: [provider: :string, color: :boolean, help: :boolean],
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

    {provider, %{color: Keyword.get(opts, :color, true)}}
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/rendering_compact.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --color / --no-color   Enable or disable ANSI colors (default: enabled)
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/rendering_compact.exs --provider claude
      mix run examples/rendering_compact.exs --provider codex --no-color
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider, opts) do
    IO.puts("Prompt: #{@prompt}")
    IO.puts("")

    case StreamSession.start(
           adapter: adapter_spec(provider),
           input: %{messages: [%{role: "user", content: @prompt}]}
         ) do
      {:ok, stream, close_fun, _meta} ->
        Rendering.stream(stream,
          renderer: {CompactRenderer, [color: opts.color]},
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

RenderingCompact.main(System.argv())
