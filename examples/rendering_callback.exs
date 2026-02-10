defmodule RenderingCallback do
  @moduledoc false

  # Runs a real provider session and uses PassthroughRenderer + CallbackSink
  # for fully programmatic event handling (no terminal rendering).
  #
  # Demonstrates:
  #   - PassthroughRenderer (no-op rendering, events pass through raw)
  #   - CallbackSink for custom event processing
  #   - Building aggregated statistics from live events
  #   - Error detection via event type inspection
  #   - Using the rendering pipeline as a programmable event processor

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.PassthroughRenderer
  alias AgentSessionManager.Rendering.Sinks.CallbackSink
  alias AgentSessionManager.SessionManager

  @prompt "Explain pattern matching in Elixir in exactly three sentences."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== CallbackSink + PassthroughRenderer (#{provider}) ===")
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
  # Argument Parsing
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

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/rendering_callback.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/rendering_callback.exs --provider claude
      mix run examples/rendering_callback.exs --provider codex
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
      IO.puts("Using PassthroughRenderer (no terminal rendering).")
      IO.puts("All events are processed via CallbackSink only.")
      IO.puts("")

      # Use an Agent to accumulate stats across events
      {:ok, stats} =
        Agent.start_link(fn ->
          %{
            events: 0,
            text_bytes: 0,
            tools: [],
            model: nil,
            stop_reason: nil,
            errors: [],
            full_text: ""
          }
        end)

      callback = fn event, _iodata ->
        Agent.update(stats, fn s ->
          s = %{s | events: s.events + 1}
          update_stats(s, event)
        end)
      end

      stream = build_event_stream(store, adapter)

      Rendering.stream(stream,
        renderer: {PassthroughRenderer, []},
        sinks: [{CallbackSink, [callback: callback]}]
      )

      # Print the aggregated stats
      final = Agent.get(stats, & &1)
      Agent.stop(stats)

      IO.puts("--- Aggregated Event Statistics ---")
      IO.puts("  Total events:    #{final.events}")
      IO.puts("  Model:           #{final.model || "unknown"}")
      IO.puts("  Text bytes:      #{final.text_bytes}")
      IO.puts("  Tools used:      #{inspect(final.tools)}")
      IO.puts("  Stop reason:     #{final.stop_reason || "n/a"}")
      IO.puts("  Errors:          #{length(final.errors)}")
      IO.puts("")

      if final.full_text != "" do
        IO.puts("--- Captured Response ---")
        IO.puts(final.full_text)
      end

      if final.errors != [] do
        IO.puts("")
        IO.puts("--- Errors ---")
        Enum.each(final.errors, &IO.puts("  #{&1}"))
      end

      :ok
    end
  end

  defp update_stats(s, %{type: :run_started, data: data}) do
    %{s | model: data[:model]}
  end

  defp update_stats(s, %{type: :message_streamed, data: data}) do
    delta = data[:delta] || data[:content] || ""
    %{s | text_bytes: s.text_bytes + byte_size(delta), full_text: s.full_text <> delta}
  end

  defp update_stats(s, %{type: :tool_call_started, data: data}) do
    %{s | tools: s.tools ++ [data[:tool_name]]}
  end

  defp update_stats(s, %{type: :run_completed, data: data}) do
    %{s | stop_reason: data[:stop_reason]}
  end

  defp update_stats(s, %{type: type, data: data})
       when type in [:error_occurred, :run_failed] do
    %{s | errors: s.errors ++ [data[:error_message] || "unknown"]}
  end

  defp update_stats(s, _event), do: s

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

RenderingCallback.main(System.argv())
