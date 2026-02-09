defmodule PermissionModeExample do
  @moduledoc false

  # Demonstrates the normalized permission_mode option on provider adapters.
  #
  # Permission modes control tool-call approval behavior per provider:
  #
  #   :default                     - provider's default handling
  #   :accept_edits                - auto-accept file edits (Claude-specific; no-op on others)
  #   :plan                        - plan mode (Claude-specific; no-op on others)
  #   :full_auto                   - skip all permission prompts
  #   :dangerously_skip_permissions - bypass all approvals and sandboxing
  #
  # Each adapter maps the normalized mode to its SDK's native semantics:
  #
  #   Claude  → permission_mode on ClaudeAgentSDK.Options
  #   Codex   → full_auto / dangerously_bypass_approvals_and_sandbox on Thread.Options
  #   Amp     → dangerously_allow_all on AmpSdk.Types.Options

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.SessionManager

  @prompt "List the files in the current directory. Keep your response to one sentence."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    {provider, mode} = parse_args(args)

    IO.puts("")
    IO.puts("=== Permission Mode Example (#{provider}, mode: #{mode}) ===")
    IO.puts("")

    case run(provider, mode) do
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
  # Command Line Argument Parsing
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

    mode = parse_mode(opts[:mode] || "full_auto")

    {provider, mode}
  end

  defp parse_mode(mode_str) do
    case AgentSessionManager.PermissionMode.normalize(mode_str) do
      {:ok, mode} when not is_nil(mode) ->
        mode

      _ ->
        IO.puts(:stderr, "Invalid mode: #{mode_str}")
        IO.puts(:stderr, "Valid modes: #{inspect(AgentSessionManager.PermissionMode.all())}")
        System.halt(1)
    end
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/permission_mode.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --mode, -m <mode>      Permission mode. Default: full_auto
                             Modes: default, accept_edits, plan, full_auto,
                                    dangerously_skip_permissions
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/permission_mode.exs --provider claude --mode full_auto
      mix run examples/permission_mode.exs --provider codex --mode dangerously_skip_permissions
      mix run examples/permission_mode.exs --provider amp --mode full_auto
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider, mode) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider, mode) do
      IO.puts("Provider:        #{provider}")
      IO.puts("Permission mode: #{mode}")
      IO.puts("Prompt:          #{@prompt}")
      IO.puts("")

      event_callback = fn event ->
        case event.type do
          :message_streamed ->
            content = event.data[:delta] || event.data[:content] || ""
            IO.write(content)

          :run_started ->
            IO.puts("Streaming...\n")

          :tool_call_started ->
            tool = event.data[:tool_name] || event.data[:name] || "unknown"
            IO.puts("\n[tool call: #{tool}]")

          :tool_call_completed ->
            IO.puts("[tool call completed]")

          :run_completed ->
            IO.puts("\n")

          _ ->
            :ok
        end
      end

      case SessionManager.run_once(
             store,
             adapter,
             %{
               messages: [%{role: "user", content: @prompt}]
             },
             context: %{system_prompt: "You are a concise technical assistant."},
             event_callback: event_callback
           ) do
        {:ok, result} ->
          IO.puts("Response: #{inspect(result.output)}")
          IO.puts("Tokens:   #{inspect(result.token_usage)}")
          IO.puts("Session:  #{result.session_id}")
          IO.puts("Run:      #{result.run_id}")
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp start_adapter("claude", mode) do
    ClaudeAdapter.start_link(permission_mode: mode)
  end

  defp start_adapter("codex", mode) do
    CodexAdapter.start_link(working_directory: File.cwd!(), permission_mode: mode)
  end

  defp start_adapter("amp", mode) do
    AmpAdapter.start_link(cwd: File.cwd!(), permission_mode: mode)
  end
end

PermissionModeExample.main(System.argv())
