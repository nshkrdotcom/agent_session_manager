defmodule RenderingStudio do
  @moduledoc false

  # Runs a real provider session and renders the event stream using
  # StudioRenderer for CLI-grade terminal output.
  #
  # Demonstrates:
  #   - Tool status lines with summary output
  #   - Tool output verbosity modes (:summary, :preview, :full)
  #   - StreamSession + Rendering pipeline wiring

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter
  }

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.StudioRenderer
  alias AgentSessionManager.Rendering.Sinks.TTYSink
  alias AgentSessionManager.StreamSession

  @prompt "Read the mix.exs file and tell me the version number."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    {provider, opts} = parse_args(args)

    IO.puts("")
    IO.puts("=== StudioRenderer (#{provider}) ===")
    IO.puts("tool_output=#{opts.tool_output}")
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
        strict: [provider: :string, tool_output: :string, help: :boolean],
        aliases: [p: :provider, t: :tool_output, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"
    tool_output = normalize_tool_output(opts[:tool_output] || "summary")

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    {provider, %{tool_output: tool_output}}
  end

  defp normalize_tool_output(value) do
    case String.downcase(value) do
      "summary" -> :summary
      "preview" -> :preview
      "full" -> :full
      _ -> invalid_tool_output(value)
    end
  end

  defp invalid_tool_output(value) do
    IO.puts(:stderr, "Unknown --tool-output value: #{value}")
    print_usage()
    System.halt(1)
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/rendering_studio.exs [options]

    Options:
      --provider, -p <name>     Provider to use (claude, codex, or amp). Default: claude
      --tool-output, -t <mode>  Tool output mode: summary, preview, or full. Default: summary
      --help, -h                Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/rendering_studio.exs --provider claude
      mix run examples/rendering_studio.exs --provider codex --tool-output preview
      mix run examples/rendering_studio.exs --provider amp --tool-output full
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
          renderer: {StudioRenderer, [tool_output: opts.tool_output]},
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

RenderingStudio.main(System.argv())
