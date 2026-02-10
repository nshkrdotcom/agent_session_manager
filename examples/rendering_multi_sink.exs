defmodule RenderingMultiSink do
  @moduledoc false

  # Runs a real provider session and renders the event stream through
  # multiple sinks simultaneously: TTY, FileSink, JSONLSink, and CallbackSink.
  #
  # Demonstrates:
  #   - Full Renderer x Sink pipeline with all four sink types
  #   - FileSink ANSI stripping (log file has no escape codes)
  #   - FileSink :io option (pre-opened file with header written before rendering)
  #   - JSONLSink full and compact modes side-by-side
  #   - CallbackSink for programmatic event tracking
  #   - Renderer selection via --mode flag (compact or verbose)

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Rendering

  alias AgentSessionManager.Rendering.Renderers.{CompactRenderer, VerboseRenderer}

  alias AgentSessionManager.Rendering.Sinks.{
    CallbackSink,
    FileSink,
    JSONLSink,
    TTYSink
  }

  alias AgentSessionManager.SessionManager

  @prompt "What are the three most important Elixir libraries for web development? One sentence each."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    {provider, opts} = parse_args(args)

    IO.puts("")
    IO.puts("=== Multi-Sink Rendering (#{provider}, #{opts.mode}) ===")
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
        strict: [provider: :string, mode: :string, help: :boolean],
        aliases: [p: :provider, m: :mode, h: :help]
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

    mode = opts[:mode] || "compact"

    unless mode in ["compact", "verbose"] do
      IO.puts(:stderr, "Unknown mode: #{mode}")
      print_usage()
      System.halt(1)
    end

    {provider, %{mode: String.to_atom(mode)}}
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/rendering_multi_sink.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --mode, -m <mode>      Renderer mode: compact or verbose. Default: compact
      --help, -h             Show this help message

    Output files (written to examples/tmp/):
      session.log            Plain-text log (ANSI stripped)
      events_full.jsonl      Full JSON Lines event log
      events_compact.jsonl   Compact JSON Lines event log

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/rendering_multi_sink.exs --provider claude
      mix run examples/rendering_multi_sink.exs --provider codex --mode verbose
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider, opts) do
    tmp_dir = Path.join(File.cwd!(), "examples/tmp")
    File.mkdir_p!(tmp_dir)

    log_path = Path.join(tmp_dir, "session.log")
    events_full_path = Path.join(tmp_dir, "events_full.jsonl")
    events_compact_path = Path.join(tmp_dir, "events_compact.jsonl")

    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider) do
      IO.puts("Prompt: #{@prompt}")
      IO.puts("Log:    #{log_path}")
      IO.puts("Events: #{events_full_path}")
      IO.puts("        #{events_compact_path}")
      IO.puts("")

      # Open log file and write a header before rendering starts
      {:ok, log_io} = File.open(log_path, [:write, :utf8])
      IO.binwrite(log_io, "Session: provider=#{provider} mode=#{opts.mode}\n\n")

      # Track events programmatically via CallbackSink
      event_counts = :counters.new(1, [:atomics])

      callback = fn event, _iodata ->
        :counters.add(event_counts, 1, 1)

        if event.type == :run_completed do
          IO.puts("\n  [callback] Run completed (stop_reason: #{event[:data][:stop_reason]})")
        end
      end

      stream = build_event_stream(store, adapter)

      renderer = renderer_for_mode(opts.mode)

      sinks = [
        {TTYSink, []},
        {FileSink, [io: log_io]},
        {JSONLSink, [path: events_full_path, mode: :full]},
        {JSONLSink, [path: events_compact_path, mode: :compact]},
        {CallbackSink, [callback: callback]}
      ]

      Rendering.stream(stream, renderer: renderer, sinks: sinks)

      File.close(log_io)

      total = :counters.get(event_counts, 1)
      IO.puts("")
      IO.puts("  [callback] Total events received: #{total}")
      IO.puts("")

      # Show file contents
      IO.puts("--- Log file (#{log_path}) ---")
      IO.puts(File.read!(log_path))

      IO.puts("--- Events full (first 5 lines) ---")
      print_first_lines(events_full_path, 5)

      IO.puts("--- Events compact (first 5 lines) ---")
      print_first_lines(events_compact_path, 5)

      :ok
    end
  end

  defp renderer_for_mode(:verbose), do: {VerboseRenderer, []}
  defp renderer_for_mode(_), do: {CompactRenderer, []}

  defp print_first_lines(path, n) do
    path
    |> File.stream!()
    |> Stream.take(n)
    |> Enum.each(&IO.write/1)

    IO.puts("")
  end

  defp build_event_stream(store, adapter) do
    parent = self()
    ref = make_ref()

    event_callback = fn event -> send(parent, {ref, :event, event}) end

    Task.start(fn ->
      result =
        SessionManager.run_once(
          store,
          adapter,
          %{messages: [%{role: "user", content: @prompt}]},
          event_callback: event_callback
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

RenderingMultiSink.main(System.argv())
