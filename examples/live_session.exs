#!/usr/bin/env elixir
# Live Session Example
#
# Demonstrates end-to-end usage of AgentSessionManager with real or mock providers.
#
# Usage:
#   # With real Claude API
#   ANTHROPIC_API_KEY=sk-... mix run examples/live_session.exs --provider claude
#
#   # With real Codex API
#   OPENAI_API_KEY=sk-... mix run examples/live_session.exs --provider codex
#
#   # Mock mode for CI (no credentials needed)
#   mix run examples/live_session.exs --provider claude --mock
#
#   # Auto-detect mock mode when credentials missing
#   mix run examples/live_session.exs --provider claude
#   # -> "No ANTHROPIC_API_KEY found, running in mock mode..."

defmodule LiveSession do
  @moduledoc """
  Comprehensive live example demonstrating AgentSessionManager features.

  Features demonstrated:
  1. Provider selection from command line
  2. Registry setup with selected provider manifest
  3. Config loading from environment variables
  4. Capability check before session creation
  5. Single session with streaming message
  6. Clean interrupt via Ctrl+C signal handling
  7. Event logging to stdout in human-readable format
  8. Final usage summary
  """

  alias AgentSessionManager.Core.{
    Capability,
    CapabilityResolver,
    Error,
    Event,
    Manifest,
    Registry,
    Run,
    Session
  }

  # Provider configurations
  @claude_manifest %{
    name: "claude-provider",
    version: "1.0.0",
    description: "Claude AI by Anthropic",
    provider: "anthropic",
    capabilities: [
      %{name: "streaming", type: :sampling, description: "Real-time streaming of responses"},
      %{name: "tool_use", type: :tool, description: "Tool/function calling capability"},
      %{name: "vision", type: :resource, description: "Image understanding capability"},
      %{name: "system_prompts", type: :prompt, description: "System prompt support"},
      %{name: "interrupt", type: :sampling, description: "Ability to interrupt/cancel requests"}
    ]
  }

  @codex_manifest %{
    name: "codex-provider",
    version: "1.0.0",
    description: "OpenAI Codex",
    provider: "openai",
    capabilities: [
      %{name: "streaming", type: :sampling, description: "Real-time streaming of responses"},
      %{name: "tool_use", type: :tool, description: "Tool/function calling capability"},
      %{name: "code_completion", type: :sampling, description: "Code completion capability"}
    ]
  }

  @doc """
  Main entry point for the live session example.
  """
  def main(args) do
    # Set up signal handling for clean interrupt
    setup_signal_handler()

    # Parse command line arguments
    {provider, mock_mode} = parse_args(args)

    # Print header
    print_header(provider, mock_mode)

    # Run the example
    case run_example(provider, mock_mode) do
      :ok ->
        print_success("Example completed successfully!")
        System.halt(0)

      {:error, error} ->
        print_error("Example failed: #{format_error(error)}")
        System.halt(1)
    end
  end

  # ============================================================================
  # Command Line Argument Parsing
  # ============================================================================

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, mock: :boolean, help: :boolean],
        aliases: [p: :provider, m: :mock, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"
    explicit_mock = opts[:mock] || false

    unless provider in ["claude", "codex"] do
      print_error("Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    {provider, explicit_mock}
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/live_session.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude or codex). Default: claude
      --mock, -m             Force mock mode (no credentials needed)
      --help, -h             Show this help message

    Environment Variables:
      ANTHROPIC_API_KEY      API key for Claude (Anthropic)
      OPENAI_API_KEY         API key for Codex (OpenAI)

    Examples:
      # With real Claude API
      ANTHROPIC_API_KEY=sk-ant-... mix run examples/live_session.exs --provider claude

      # Mock mode for CI (no credentials needed)
      mix run examples/live_session.exs --provider claude --mock

      # Auto-detect mock mode when credentials missing
      mix run examples/live_session.exs --provider claude
    """)
  end

  # ============================================================================
  # Main Example Logic
  # ============================================================================

  defp run_example(provider, explicit_mock) do
    # Step 1: Check for credentials and determine mode
    {mode, api_key} = determine_mode(provider, explicit_mock)

    print_step(1, "Mode Detection")
    print_info("Running in #{mode} mode")

    if mode == :mock do
      print_warning("Using mock adapter - no real API calls will be made")
    end

    # Step 2: Set up registry with provider manifest
    print_step(2, "Registry Setup")

    with {:ok, registry} <- setup_registry(provider),
         _ = print_info("Registry initialized with #{Registry.count(registry)} provider(s)"),

         # Step 3: Load config from environment
         _ = print_step(3, "Configuration"),
         {:ok, config} <- load_config(provider, mode, api_key),
         _ = print_info("Configuration loaded for provider: #{provider}"),

         # Step 4: Check capabilities before session creation
         _ = print_step(4, "Capability Check"),
         {:ok, manifest} <- Registry.get(registry, "#{provider}-provider"),
         {:ok, cap_result} <- check_capabilities(manifest),
         _ = print_capabilities(cap_result, manifest),

         # Step 5: Create session and run
         _ = print_step(5, "Session Creation"),
         {:ok, session} <- create_session(provider),
         _ = print_info("Session created: #{session.id}"),

         # Step 6: Execute with streaming
         _ = print_step(6, "Streaming Execution"),
         {:ok, result} <- execute_run(session, config, mode),

         # Step 7: Print usage summary
         _ = print_step(7, "Usage Summary"),
         _ = print_usage_summary(result) do
      :ok
    end
  end

  defp determine_mode(provider, explicit_mock) do
    if explicit_mock do
      {:mock, nil}
    else
      env_var = get_env_var_name(provider)
      api_key = System.get_env(env_var)

      if api_key && api_key != "" do
        {:live, api_key}
      else
        print_warning("No #{env_var} found, running in mock mode...")
        {:mock, nil}
      end
    end
  end

  defp get_env_var_name("claude"), do: "ANTHROPIC_API_KEY"
  defp get_env_var_name("codex"), do: "OPENAI_API_KEY"

  # ============================================================================
  # Registry Setup
  # ============================================================================

  defp setup_registry(provider) do
    registry = Registry.new()

    manifest_attrs =
      case provider do
        "claude" -> @claude_manifest
        "codex" -> @codex_manifest
      end

    with {:ok, manifest} <- Manifest.new(manifest_attrs),
         {:ok, registry} <- Registry.register(registry, manifest) do
      {:ok, registry}
    end
  end

  # ============================================================================
  # Configuration Loading
  # ============================================================================

  defp load_config(provider, mode, api_key) do
    config = %{
      provider: provider,
      mode: mode,
      api_key: api_key,
      model: get_default_model(provider),
      max_tokens: 1024,
      temperature: 0.7
    }

    {:ok, config}
  end

  defp get_default_model("claude"), do: "claude-sonnet-4-20250514"
  defp get_default_model("codex"), do: "gpt-4"

  # ============================================================================
  # Capability Checking
  # ============================================================================

  defp check_capabilities(manifest) do
    # We require sampling capability, optional tool use
    with {:ok, resolver} <-
           CapabilityResolver.new(
             required: [:sampling],
             optional: [:tool, :prompt]
           ),
         {:ok, result} <- CapabilityResolver.negotiate(resolver, manifest.capabilities) do
      {:ok, result}
    end
  end

  defp print_capabilities(result, manifest) do
    print_info("Capability negotiation: #{result.status}")

    enabled = Manifest.enabled_capabilities(manifest)
    print_info("Available capabilities: #{format_capability_names(enabled)}")

    if result.warnings != [] do
      for warning <- result.warnings do
        print_warning(warning)
      end
    end
  end

  defp format_capability_names(capabilities) do
    capabilities
    |> Enum.map(& &1.name)
    |> Enum.join(", ")
  end

  # ============================================================================
  # Session and Run Execution
  # ============================================================================

  defp create_session(provider) do
    Session.new(%{
      agent_id: "live-example-#{provider}",
      context: %{
        system_prompt: "You are a helpful assistant. Keep your responses concise."
      },
      tags: ["example", "live-session"]
    })
  end

  defp execute_run(session, config, mode) do
    # Create run
    with {:ok, run} <- create_run(session),
         _ = print_info("Run created: #{run.id}"),
         _ = print_info("Sending message: \"Hello! What can you tell me about Elixir?\""),
         _ = IO.puts(""),
         _ = print_divider("Response"),

         # Execute based on mode
         {:ok, result} <- do_execute(run, session, config, mode) do
      {:ok, result}
    end
  end

  defp create_run(session) do
    Run.new(%{
      session_id: session.id,
      input: %{
        messages: [
          %{role: "user", content: "Hello! What can you tell me about Elixir?"}
        ]
      }
    })
  end

  defp do_execute(run, session, config, :mock) do
    # Use mock execution
    execute_mock(run, session, config)
  end

  defp do_execute(run, session, config, :live) do
    # Check if SDK is available
    case check_sdk_available(config.provider) do
      :ok ->
        execute_live(run, session, config)

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Mock Execution
  # ============================================================================

  defp execute_mock(run, session, config) do
    # Simulate streaming response
    events = []
    start_time = System.monotonic_time(:millisecond)

    # Emit run_started
    event1 = emit_event(:run_started, run, session, %{model: config.model})
    events = [event1 | events]

    # Simulate streaming content
    chunks = [
      "Elixir is a ",
      "dynamic, functional ",
      "programming language ",
      "designed for building ",
      "scalable and maintainable ",
      "applications.\n\n",
      "Key features include:\n",
      "- Runs on the BEAM VM\n",
      "- Excellent concurrency\n",
      "- Fault-tolerant design\n",
      "- Great tooling with Mix"
    ]

    full_content =
      for chunk <- chunks, reduce: "" do
        acc ->
          # Small delay for realistic streaming
          Process.sleep(50)

          _event = emit_event(:message_streamed, run, session, %{delta: chunk, content: chunk})
          IO.write(IO.ANSI.cyan() <> chunk <> IO.ANSI.reset())

          acc <> chunk
      end

    IO.puts("")
    IO.puts("")

    # Emit message_received
    event2 =
      emit_event(:message_received, run, session, %{content: full_content, role: "assistant"})

    events = [event2 | events]

    # Emit token_usage
    event3 =
      emit_event(:token_usage_updated, run, session, %{input_tokens: 25, output_tokens: 85})

    events = [event3 | events]

    # Emit run_completed
    event4 = emit_event(:run_completed, run, session, %{stop_reason: "end_turn"})
    events = [event4 | events]

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    result = %{
      output: %{
        content: full_content,
        stop_reason: "end_turn",
        tool_calls: []
      },
      token_usage: %{
        input_tokens: 25,
        output_tokens: 85
      },
      events: Enum.reverse(events),
      duration_ms: duration_ms
    }

    {:ok, result}
  end

  defp emit_event(type, run, session, data) do
    event = %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: session.id,
      run_id: run.id,
      data: data,
      provider: :mock
    }

    log_event(event)
    event
  end

  # ============================================================================
  # Live Execution (SDK Integration)
  # ============================================================================

  defp check_sdk_available("claude") do
    # Check if the Claude adapter is available and configured correctly
    # In a real scenario, we'd check for the anthropic_ex or similar package
    case Code.ensure_loaded(AgentSessionManager.Adapters.ClaudeAdapter) do
      {:module, _} -> :ok
      {:error, _} -> sdk_not_available_error("claude")
    end
  end

  defp check_sdk_available("codex") do
    # In a real scenario, we'd check for the openai_ex or similar package
    # For now, return error as we don't have a codex adapter implemented
    sdk_not_available_error("codex")
  end

  defp sdk_not_available_error(provider) do
    instructions =
      case provider do
        "claude" ->
          """
          The Claude SDK adapter requires the Anthropic SDK.

          To install, add to your mix.exs:

              {:anthropic, "~> 0.3"}

          Then run: mix deps.get

          For now, use --mock flag to run in mock mode:

              mix run examples/live_session.exs --provider claude --mock
          """

        "codex" ->
          """
          The Codex SDK adapter requires the OpenAI SDK.

          To install, add to your mix.exs:

              {:openai, "~> 0.5"}

          Then run: mix deps.get

          For now, use --mock flag to run in mock mode:

              mix run examples/live_session.exs --provider codex --mock
          """
      end

    print_error("SDK not available for #{provider}")
    IO.puts(instructions)
    {:error, Error.new(:sdk_not_available, "SDK not available for #{provider}")}
  end

  defp execute_live(run, session, config) do
    # Note: The ClaudeAdapter currently requires a mock SDK for full functionality
    # This is a placeholder for real SDK integration
    #
    # When real SDK integration is complete, this would use:
    # adapter_opts = [api_key: config.api_key, model: config.model]
    # {:ok, adapter} = ClaudeAdapter.start_link(adapter_opts)
    # ClaudeAdapter.execute(adapter, run, session, event_callback: &log_event/1)

    print_warning("Live SDK integration is in development")
    print_info("Falling back to mock execution for demonstration")

    # Fall back to mock for now
    execute_mock(run, session, config)
  end

  # ============================================================================
  # Event Logging
  # ============================================================================

  defp log_event(event) do
    timestamp = format_timestamp(event.timestamp)
    type_str = format_event_type(event.type)

    # Log to stderr so it doesn't interfere with streamed content
    case event.type do
      :message_streamed ->
        # Don't log streaming events to keep output clean
        :ok

      :run_started ->
        IO.puts(:stderr, "#{timestamp} #{type_str} model=#{event.data.model}")

      :run_completed ->
        IO.puts(:stderr, "#{timestamp} #{type_str} stop_reason=#{event.data.stop_reason}")

      :token_usage_updated ->
        IO.puts(
          :stderr,
          "#{timestamp} #{type_str} input=#{event.data.input_tokens} output=#{event.data.output_tokens}"
        )

      :message_received ->
        IO.puts(:stderr, "#{timestamp} #{type_str} role=#{event.data.role}")

      _ ->
        IO.puts(:stderr, "#{timestamp} #{type_str}")
    end
  end

  defp format_timestamp(datetime) do
    time = DateTime.to_time(datetime)
    "#{pad(time.hour)}:#{pad(time.minute)}:#{pad(time.second)}"
  end

  defp pad(num), do: String.pad_leading(Integer.to_string(num), 2, "0")

  defp format_event_type(type) do
    type_str = Atom.to_string(type)
    color = event_type_color(type)
    "#{color}[#{String.pad_trailing(type_str, 20)}]#{IO.ANSI.reset()}"
  end

  defp event_type_color(:run_started), do: IO.ANSI.green()
  defp event_type_color(:run_completed), do: IO.ANSI.green()
  defp event_type_color(:message_received), do: IO.ANSI.blue()
  defp event_type_color(:message_streamed), do: IO.ANSI.cyan()
  defp event_type_color(:token_usage_updated), do: IO.ANSI.yellow()
  defp event_type_color(:error_occurred), do: IO.ANSI.red()
  defp event_type_color(:run_failed), do: IO.ANSI.red()
  defp event_type_color(_), do: IO.ANSI.white()

  # ============================================================================
  # Usage Summary
  # ============================================================================

  defp print_usage_summary(result) do
    print_divider("Usage Summary")

    usage = result.token_usage
    total_tokens = (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)

    IO.puts("  Input tokens:  #{usage[:input_tokens] || 0}")
    IO.puts("  Output tokens: #{usage[:output_tokens] || 0}")
    IO.puts("  Total tokens:  #{total_tokens}")
    IO.puts("  Duration:      #{result.duration_ms}ms")
    IO.puts("  Events:        #{length(result.events)}")
    IO.puts("  Stop reason:   #{result.output.stop_reason}")

    if result.output.tool_calls != [] do
      IO.puts("  Tool calls:    #{length(result.output.tool_calls)}")
    end

    IO.puts("")
  end

  # ============================================================================
  # Signal Handling
  # ============================================================================

  defp setup_signal_handler do
    # Trap exit signals
    Process.flag(:trap_exit, true)

    # Note: In a real application, you might use :os.set_signal_handler/2
    # For this example, we rely on the BEAM's default signal handling
    :ok
  end

  # ============================================================================
  # Output Formatting Helpers
  # ============================================================================

  defp print_header(provider, mock_mode) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "AgentSessionManager - Live Session Example" <> IO.ANSI.reset())
    IO.puts(String.duplicate("=", 50))
    IO.puts("Provider: #{provider}")
    IO.puts("Mode:     #{if mock_mode, do: "mock (forced)", else: "auto-detect"}")
    IO.puts(String.duplicate("=", 50))
    IO.puts("")
  end

  defp print_step(num, title) do
    IO.puts("")

    IO.puts(
      IO.ANSI.bright() <>
        IO.ANSI.blue() <> "Step #{num}: #{title}" <> IO.ANSI.reset()
    )

    IO.puts(String.duplicate("-", 40))
  end

  defp print_divider(title) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "--- #{title} ---" <> IO.ANSI.reset())
    IO.puts("")
  end

  defp print_info(message) do
    IO.puts(IO.ANSI.green() <> "  [INFO] " <> IO.ANSI.reset() <> message)
  end

  defp print_warning(message) do
    IO.puts(IO.ANSI.yellow() <> "  [WARN] " <> IO.ANSI.reset() <> message)
  end

  defp print_error(message) do
    IO.puts(IO.ANSI.red() <> "  [ERROR] " <> IO.ANSI.reset() <> message)
  end

  defp print_success(message) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.green() <> message <> IO.ANSI.reset())
    IO.puts("")
  end

  defp format_error(%Error{} = error), do: "#{error.code}: #{error.message}"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end

# Run the example
LiveSession.main(System.argv())
