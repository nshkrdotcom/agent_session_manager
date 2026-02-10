defmodule StreamSessionExample do
  @moduledoc false

  # Demonstrates StreamSession: the one-shot streaming session lifecycle
  # that replaces ~35 lines of hand-rolled boilerplate with a single call.
  #
  # StreamSession handles:
  #   - Store creation (InMemorySessionStore by default)
  #   - Adapter start_link (from {Module, opts} tuple)
  #   - Task launch (SessionManager.run_once with event bridging)
  #   - Lazy Stream.resource with idle timeout and crash handling
  #   - Idempotent close_fun for cleanup
  #
  # This example exercises StreamSession in two modes:
  #   1. Rendering mode:  StreamSession + CompactRenderer + TTYSink
  #   2. Raw stream mode: StreamSession events consumed directly
  #
  # Usage:
  #   mix run examples/stream_session.exs --provider claude
  #   mix run examples/stream_session.exs --provider codex --mode raw
  #   mix run examples/stream_session.exs --provider amp --no-color

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter
  }

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.CompactRenderer
  alias AgentSessionManager.Rendering.Sinks.TTYSink
  alias AgentSessionManager.StreamSession

  @prompt "Explain the actor model in three sentences. Be concise."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    {provider, opts} = parse_args(args)

    IO.puts("")
    IO.puts("=== StreamSession (#{provider}, mode: #{opts.mode}) ===")
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
        strict: [provider: :string, color: :boolean, mode: :string, help: :boolean],
        aliases: [p: :provider, m: :mode, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"
    mode = opts[:mode] || "rendering"

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    unless mode in ["rendering", "raw"] do
      IO.puts(:stderr, "Unknown mode: #{mode}")
      print_usage()
      System.halt(1)
    end

    {provider, %{color: Keyword.get(opts, :color, true), mode: mode}}
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/stream_session.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --mode, -m <mode>      Output mode: "rendering" or "raw". Default: rendering
      --color / --no-color   Enable or disable ANSI colors (default: enabled)
      --help, -h             Show this help message

    Modes:
      rendering  Use CompactRenderer + TTYSink for formatted terminal output
      raw        Consume the event stream directly and print event types

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/stream_session.exs --provider claude
      mix run examples/stream_session.exs --provider codex --mode raw
      mix run examples/stream_session.exs --provider amp --no-color
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider, opts) do
    IO.puts("Prompt: #{@prompt}")
    IO.puts("")

    adapter_spec = adapter_spec(provider)

    # StreamSession replaces ~35 lines of boilerplate with a single call:
    #   - Starts an InMemorySessionStore automatically
    #   - Starts the adapter from the {Module, opts} tuple
    #   - Launches a task running SessionManager.run_once
    #   - Returns a lazy event stream + idempotent close function
    case StreamSession.start(
           adapter: adapter_spec,
           input: %{messages: [%{role: "user", content: @prompt}]},
           agent_id: "stream-session-example"
         ) do
      {:ok, stream, close_fun, meta} ->
        IO.puts("Meta: #{inspect(meta)}")
        IO.puts("")

        result = consume_stream(stream, opts)
        close_fun.()
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Rendering mode: pipe through CompactRenderer + TTYSink
  defp consume_stream(stream, %{mode: "rendering"} = opts) do
    Rendering.stream(stream,
      renderer: {CompactRenderer, [color: opts.color]},
      sinks: [{TTYSink, []}]
    )
  end

  # -- Raw mode: consume events directly and print summaries
  defp consume_stream(stream, %{mode: "raw"}) do
    events =
      stream
      |> Stream.each(fn event ->
        print_raw_event(event)
      end)
      |> Enum.to_list()

    IO.puts("")
    IO.puts("--- Summary ---")
    IO.puts("Total events: #{length(events)}")

    types = events |> Enum.map(& &1.type) |> Enum.frequencies()

    types
    |> Enum.sort_by(fn {_type, count} -> -count end)
    |> Enum.each(fn {type, count} ->
      IO.puts("  #{type}: #{count}")
    end)

    :ok
  end

  defp print_raw_event(%{type: :message_streamed, data: data}) do
    content = data[:delta] || data[:content] || ""
    IO.write(content)
  end

  defp print_raw_event(%{type: :run_started}) do
    IO.puts("[run_started]")
  end

  defp print_raw_event(%{type: :run_completed, data: data}) do
    IO.puts("")
    IO.puts("[run_completed] tokens: #{inspect(data[:token_usage])}")
  end

  defp print_raw_event(%{type: :error_occurred, data: data}) do
    IO.puts("[error] #{data[:error_message]}")
  end

  defp print_raw_event(%{type: type}) do
    IO.puts("[#{type}]")
  end

  # ============================================================================
  # Adapter Specs
  # ============================================================================

  defp adapter_spec("claude"), do: {ClaudeAdapter, []}
  defp adapter_spec("codex"), do: {CodexAdapter, working_directory: File.cwd!()}
  defp adapter_spec("amp"), do: {AmpAdapter, cwd: File.cwd!()}
end

StreamSessionExample.main(System.argv())
