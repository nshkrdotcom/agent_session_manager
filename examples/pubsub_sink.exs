defmodule PubSubSinkExample do
  @moduledoc false

  # Demonstrates PubSub integration with AgentSessionManager.
  #
  # Two paths are shown:
  #   1. PubSubSink in the rendering pipeline (broadcasts events from stream)
  #   2. PubSub.event_callback bridge (broadcasts events from SessionManager callback)
  #
  # Both use Phoenix.PubSub for delivery and share the same topic naming convention.

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter
  }

  alias AgentSessionManager.PubSub, as: ASMPubSub
  alias AgentSessionManager.PubSub.Topic
  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.PassthroughRenderer
  alias AgentSessionManager.Rendering.Sinks.PubSubSink
  alias AgentSessionManager.StreamSession

  @prompt "Name three colors. One word each, separated by commas."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== PubSub Integration (#{provider}) ===")
    IO.puts("")

    # Start a PubSub server
    {:ok, _} = start_pubsub(__MODULE__.PubSub)

    case run_sink_path(provider) do
      :ok ->
        IO.puts("")
        IO.puts("--- Path 2: event_callback bridge ---")
        IO.puts("")
        run_callback_path(provider)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{inspect(reason)}")
        System.halt(1)
    end

    IO.puts("")
    IO.puts("Done.")
    System.halt(0)
  end

  # ============================================================================
  # Path 1: PubSubSink in the Rendering Pipeline
  # ============================================================================

  defp run_sink_path(provider) do
    IO.puts("--- Path 1: PubSubSink in rendering pipeline ---")
    IO.puts("Prompt: #{@prompt}")
    IO.puts("")

    # We subscribe and collect events after the stream completes
    # (since we are running synchronously on a single process).
    # In a real app, a separate process (LiveView, GenServer) would subscribe.

    case StreamSession.start(
           adapter: adapter_spec(provider),
           input: %{messages: [%{role: "user", content: @prompt}]}
         ) do
      {:ok, stream, close_fun, meta} ->
        # Get session_id from meta to subscribe
        session_id = meta[:session_id] || "unknown"
        topic = Topic.build_session_topic("asm", session_id)
        Phoenix.PubSub.subscribe(__MODULE__.PubSub, topic)

        IO.puts("Subscribed to topic: #{topic}")
        IO.puts("Rendering stream with PubSubSink...")
        IO.puts("")

        Rendering.stream(stream,
          renderer: {PassthroughRenderer, []},
          sinks: [
            {PubSubSink,
             [
               pubsub: __MODULE__.PubSub,
               scope: :session
             ]}
          ]
        )

        close_fun.()

        # Drain PubSub messages from our mailbox
        events = drain_pubsub_messages()

        IO.puts("Received #{length(events)} events via PubSub:")

        Enum.each(events, fn {_wrapper, _sid, event} ->
          IO.puts("  #{event.type}")
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Path 2: event_callback Bridge
  # ============================================================================

  defp run_callback_path(provider) do
    IO.puts("Prompt: #{@prompt}")
    IO.puts("")

    session_id_holder = :ets.new(:session_holder, [:set, :public])

    # Create a PubSub event callback
    pubsub_callback = ASMPubSub.event_callback(__MODULE__.PubSub, scope: :session)

    # Wrap it to also capture session_id on first event
    wrapped_callback = fn event_data ->
      # Subscribe on first event
      case :ets.lookup(session_id_holder, :subscribed) do
        [] ->
          sid = event_data[:session_id]
          topic = Topic.build_session_topic("asm", sid)
          Phoenix.PubSub.subscribe(__MODULE__.PubSub, topic)
          :ets.insert(session_id_holder, {:subscribed, true})
          IO.puts("Subscribed to topic: #{topic}")

        _ ->
          :ok
      end

      pubsub_callback.(event_data)
    end

    # Use StreamSession with the event_callback option
    case StreamSession.start(
           adapter: adapter_spec(provider),
           input: %{messages: [%{role: "user", content: @prompt}]},
           event_callback: wrapped_callback
         ) do
      {:ok, stream, close_fun, _meta} ->
        # Consume the stream (just drain it)
        Stream.run(stream)
        close_fun.()

        # Drain PubSub messages
        events = drain_pubsub_messages()

        IO.puts("")
        IO.puts("Received #{length(events)} events via PubSub (callback bridge):")

        Enum.each(events, fn {_wrapper, _sid, event} ->
          type_str =
            if is_map(event) do
              "#{event[:type] || event.type}"
            else
              inspect(event)
            end

          IO.puts("  #{type_str}")
        end)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
    end

    :ets.delete(session_id_holder)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc false
  def start_pubsub(name) do
    Supervisor.start_link([{Phoenix.PubSub, name: name}], strategy: :one_for_one)
  end

  defp drain_pubsub_messages(acc \\ []) do
    receive do
      {:asm_event, _session_id, _event} = msg ->
        drain_pubsub_messages(acc ++ [msg])
    after
      100 -> acc
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

    Usage: mix run examples/pubsub_sink.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/pubsub_sink.exs --provider claude
      mix run examples/pubsub_sink.exs --provider codex
    """)
  end

  defp adapter_spec("claude"), do: {ClaudeAdapter, []}
  defp adapter_spec("codex"), do: {CodexAdapter, working_directory: File.cwd!()}
  defp adapter_spec("amp"), do: {AmpAdapter, cwd: File.cwd!()}
end

PubSubSinkExample.main(System.argv())
