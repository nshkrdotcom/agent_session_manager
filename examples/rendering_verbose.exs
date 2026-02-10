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
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.VerboseRenderer
  alias AgentSessionManager.Rendering.Sinks.TTYSink
  alias AgentSessionManager.SessionManager

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
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider) do
      IO.puts("Prompt: #{@prompt}")
      IO.puts("")

      stream = build_event_stream(store, adapter)

      Rendering.stream(stream,
        renderer: {VerboseRenderer, [color: color]},
        sinks: [{TTYSink, []}]
      )
    end
  end

  defp build_event_stream(store, adapter) do
    parent = self()
    ref = make_ref()

    callback = fn event -> send(parent, {ref, :event, event}) end

    Task.start(fn ->
      result =
        SessionManager.run_once(
          store,
          adapter,
          %{messages: [%{role: "user", content: @prompt}]},
          event_callback: callback
        )

      send(parent, {ref, :done, result})
    end)

    Stream.resource(
      fn -> :running end,
      fn
        :done ->
          {:halt, :done}

        :running ->
          receive do
            {^ref, :event, event} -> {[event], :running}
            {^ref, :done, _result} -> {:halt, :done}
          after
            120_000 -> {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp start_adapter("claude"), do: ClaudeAdapter.start_link([])
  defp start_adapter("codex"), do: CodexAdapter.start_link(working_directory: File.cwd!())
  defp start_adapter("amp"), do: AmpAdapter.start_link(cwd: File.cwd!())
end

RenderingVerbose.main(System.argv())
