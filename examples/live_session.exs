#!/usr/bin/env elixir
# Live Session Example
#
# Demonstrates end-to-end usage of AgentSessionManager with real providers.
# Authentication is handled by each SDK's login mechanism:
#
#   - Claude: `claude login` or ANTHROPIC_API_KEY env var
#   - Codex:  `codex login` or CODEX_API_KEY env var
#
# Usage:
#   mix run examples/live_session.exs --provider claude
#   mix run examples/live_session.exs --provider codex

defmodule LiveSession do
  @moduledoc """
  Comprehensive live example demonstrating AgentSessionManager features.

  Features demonstrated:
  1. Provider selection from command line
  2. Registry setup with selected provider manifest
  3. Configuration and capability negotiation
  4. Session creation and streaming execution via adapter
  5. Event logging to stderr in human-readable format
  6. Final usage summary
  """

  alias AgentSessionManager.Core.{
    CapabilityResolver,
    Error,
    Manifest,
    Registry,
    Run,
    Session
  }

  alias AgentSessionManager.Ports.ProviderAdapter
  alias AgentSessionManager.Adapters.{ClaudeAdapter, CodexAdapter}

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
      %{name: "system_prompts", type: :prompt, description: "System prompt support"},
      %{name: "code_completion", type: :sampling, description: "Code completion capability"}
    ]
  }

  @doc """
  Main entry point for the live session example.
  """
  def main(args) do
    setup_signal_handler()

    provider = parse_args(args)
    print_header(provider)

    case run_example(provider) do
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
        strict: [provider: :string, help: :boolean],
        aliases: [p: :provider, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex"] do
      print_error("Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/live_session.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude or codex). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY

    Examples:
      mix run examples/live_session.exs --provider claude
      mix run examples/live_session.exs --provider codex
    """)
  end

  # ============================================================================
  # Main Example Logic
  # ============================================================================

  defp run_example(provider) do
    # Step 1: Set up registry with provider manifest
    print_step(1, "Registry Setup")

    with {:ok, registry} <- setup_registry(provider),
         _ = print_info("Registry initialized with #{Registry.count(registry)} provider(s)"),

         # Step 2: Load config
         _ = print_step(2, "Configuration"),
         {:ok, config} <- load_config(provider),
         _ = print_info("Configuration loaded for provider: #{provider}"),

         # Step 3: Check capabilities before session creation
         _ = print_step(3, "Capability Check"),
         {:ok, manifest} <- Registry.get(registry, "#{provider}-provider"),
         {:ok, cap_result} <- check_capabilities(manifest),
         _ = print_capabilities(cap_result, manifest),

         # Step 4: Start adapter
         _ = print_step(4, "Adapter Setup"),
         {:ok, adapter} <- start_adapter(config),
         _ = print_info("Adapter started for provider: #{provider}"),

         # Step 5: Create session and run
         _ = print_step(5, "Session Creation"),
         {:ok, session} <- create_session(provider),
         _ = print_info("Session created: #{session.id}"),

         # Step 6: Execute with streaming
         _ = print_step(6, "Streaming Execution"),
         {:ok, result} <- execute_run(adapter, session, config),

         # Step 7: Print usage summary
         _ = print_step(7, "Usage Summary"),
         _ = print_usage_summary(result) do
      :ok
    end
  end

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
  # Configuration
  # ============================================================================

  defp load_config(provider) do
    config = %{
      provider: provider,
      model: get_default_model(provider)
    }

    {:ok, config}
  end

  defp get_default_model("claude"), do: "claude-sonnet-4-20250514"
  defp get_default_model("codex"), do: nil

  # ============================================================================
  # Capability Checking
  # ============================================================================

  defp check_capabilities(manifest) do
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
  # Adapter Setup
  # ============================================================================

  defp start_adapter(%{provider: "claude"} = config) do
    case check_sdk_available("claude") do
      :ok ->
        ClaudeAdapter.start_link(model: config.model)

      {:error, _} = error ->
        error
    end
  end

  defp start_adapter(%{provider: "codex"} = config) do
    case check_sdk_available("codex") do
      :ok ->
        CodexAdapter.start_link(
          working_directory: File.cwd!(),
          model: config.model
        )

      {:error, _} = error ->
        error
    end
  end

  defp check_sdk_available("claude") do
    case Code.ensure_loaded(AgentSessionManager.Adapters.ClaudeAdapter) do
      {:module, _} -> :ok
      {:error, _} -> sdk_not_available_error("claude")
    end
  end

  defp check_sdk_available("codex") do
    case Code.ensure_loaded(AgentSessionManager.Adapters.CodexAdapter) do
      {:module, _} -> :ok
      {:error, _} -> sdk_not_available_error("codex")
    end
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
          """

        "codex" ->
          """
          The Codex SDK adapter requires the OpenAI SDK.

          To install, add to your mix.exs:

              {:openai, "~> 0.5"}

          Then run: mix deps.get
          """
      end

    print_error("SDK not available for #{provider}")
    IO.puts(instructions)
    {:error, Error.new(:sdk_not_available, "SDK not available for #{provider}")}
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

  defp execute_run(adapter, session, _config) do
    with {:ok, run} <- create_run(session),
         _ = print_info("Run created: #{run.id}"),
         _ = print_info("Sending message: \"Hello! What can you tell me about Elixir?\""),
         _ = IO.puts(""),
         _ = print_divider("Response") do
      event_callback = fn event_data -> handle_live_event(event_data) end

      start_time = System.monotonic_time(:millisecond)

      result =
        ProviderAdapter.execute(adapter, run, session,
          event_callback: event_callback,
          timeout: 120_000
        )

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      case result do
        {:ok, adapter_result} ->
          IO.puts("")
          IO.puts("")
          {:ok, Map.put(adapter_result, :duration_ms, duration_ms)}

        {:error, error} ->
          {:error, error}
      end
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

  # ============================================================================
  # Live Event Handling
  # ============================================================================

  defp handle_live_event(%{type: :message_streamed, data: data}) do
    content = data[:delta] || data[:content] || ""
    IO.write(IO.ANSI.cyan() <> content <> IO.ANSI.reset())
  end

  defp handle_live_event(%{type: type, data: data}) do
    timestamp = format_timestamp(DateTime.utc_now())
    type_str = format_event_type(type)

    case type do
      :run_started ->
        model = data[:model] || "default"
        IO.puts(:stderr, "#{timestamp} #{type_str} model=#{model}")

      :run_completed ->
        stop_reason = data[:stop_reason] || data[:status] || "unknown"
        IO.puts(:stderr, "#{timestamp} #{type_str} stop_reason=#{stop_reason}")

      :token_usage_updated ->
        input = trunc(data[:input_tokens] || 0)
        output = trunc(data[:output_tokens] || 0)
        IO.puts(:stderr, "#{timestamp} #{type_str} input=#{input} output=#{output}")

      :message_received ->
        role = data[:role] || "unknown"
        IO.puts(:stderr, "#{timestamp} #{type_str} role=#{role}")

      _ ->
        IO.puts(:stderr, "#{timestamp} #{type_str}")
    end
  end

  defp handle_live_event(_event), do: :ok

  # ============================================================================
  # Output Formatting
  # ============================================================================

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
    input = trunc(usage[:input_tokens] || 0)
    output = trunc(usage[:output_tokens] || 0)
    total = input + output

    IO.puts("  Input tokens:  #{input}")
    IO.puts("  Output tokens: #{output}")
    IO.puts("  Total tokens:  #{total}")
    IO.puts("  Duration:      #{result[:duration_ms] || 0}ms")

    stop_reason = get_in(result, [:output, :stop_reason]) || get_in(result, [:output, :status])

    if stop_reason do
      IO.puts("  Stop reason:   #{stop_reason}")
    end

    tool_calls = get_in(result, [:output, :tool_calls]) || []

    if tool_calls != [] do
      IO.puts("  Tool calls:    #{length(tool_calls)}")
    end

    IO.puts("")
  end

  # ============================================================================
  # Signal Handling
  # ============================================================================

  defp setup_signal_handler do
    Process.flag(:trap_exit, true)
    :ok
  end

  # ============================================================================
  # Output Formatting Helpers
  # ============================================================================

  defp print_header(provider) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "AgentSessionManager - Live Session Example" <> IO.ANSI.reset())
    IO.puts(String.duplicate("=", 50))
    IO.puts("Provider: #{provider}")
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
