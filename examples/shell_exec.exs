defmodule ShellExec do
  @moduledoc false

  # Demonstrates mixed real-provider + shell execution.
  #
  # This example uses real provider adapters (Claude/Codex/Amp) and real shell
  # commands through ShellAdapter and Workspace.Exec.

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore,
    ShellAdapter
  }

  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Workspace.Exec

  @provider_prompt "Reply with one short line confirming shell integration is ready."

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Shell Exec Example (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("")
        IO.puts("Done.")

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

    Usage: mix run examples/shell_exec.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    This example demonstrates mixed execution:
    - Real provider adapter execution (Claude/Codex/Amp)
    - Real shell command execution via ShellAdapter + Workspace.Exec

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/shell_exec.exs --provider claude
      mix run examples/shell_exec.exs --provider codex
      mix run examples/shell_exec.exs --provider amp
    """)
  end

  # ============================================================================
  # Main Logic
  # ============================================================================

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, provider_adapter} <- start_provider_adapter(provider),
         {:ok, shell_adapter} <- ShellAdapter.start_link(cwd: File.cwd!()),
         :ok <- run_provider_demo(store, provider_adapter, provider),
         :ok <- run_shell_demos(store, shell_adapter) do
      :ok
    end
  end

  defp run_provider_demo(store, provider_adapter, provider) do
    IO.puts("--- Demo 0: Real #{String.upcase(provider)} CLI ---")
    IO.puts("")
    IO.puts("Prompt: #{@provider_prompt}")

    event_callback = fn event ->
      case event.type do
        :run_started ->
          IO.puts("  [run_started]")

        :message_streamed ->
          delta = event.data[:delta] || event.data[:content] || ""
          if is_binary(delta) and delta != "", do: IO.write(delta)

        :run_completed ->
          IO.puts("\n  [run_completed]")

        :run_failed ->
          IO.puts("\n  [run_failed]")

        _ ->
          :ok
      end
    end

    case SessionManager.run_once(
           store,
           provider_adapter,
           %{messages: [%{role: "user", content: @provider_prompt}]},
           event_callback: event_callback
         ) do
      {:ok, result} ->
        IO.puts("  Output:    #{extract_output_content(result.output)}")
        IO.puts("  Tokens:    #{inspect(result.token_usage)}")
        IO.puts("  Session:   #{result.session_id}")
        IO.puts("  Run:       #{result.run_id}")
        IO.puts("")
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp run_shell_demos(store, adapter) do
    event_callback = fn event ->
      case event.type do
        :run_started ->
          IO.puts("  [run_started]")

        :tool_call_started ->
          IO.puts("  [tool_call_started] #{event.data.tool_name}")

        :tool_call_completed ->
          IO.puts("  [tool_call_completed] exit=#{event.data.tool_output.exit_code}")

        :tool_call_failed ->
          IO.puts("  [tool_call_failed] exit=#{event.data.tool_output.exit_code}")

        :run_completed ->
          IO.puts("  [run_completed] #{event.data.stop_reason} (#{event.data.duration_ms}ms)")

        :run_failed ->
          IO.puts("  [run_failed] #{event.data.error_code}")

        _ ->
          :ok
      end
    end

    # --- Demo 1: Simple command ---
    IO.puts("--- Demo 1: Simple Command ---")
    IO.puts("")

    case SessionManager.run_once(store, adapter, "echo 'Hello from ShellAdapter!'",
           event_callback: event_callback
         ) do
      {:ok, result} ->
        IO.puts("")
        IO.puts("  Output:    #{String.trim(result.output.content)}")
        IO.puts("  Exit code: #{result.output.exit_code}")
        IO.puts("  Tokens:    #{inspect(result.token_usage)}")
        IO.puts("  Session:   #{result.session_id}")
        IO.puts("  Run:       #{result.run_id}")

      {:error, error} ->
        IO.puts("  Error: #{inspect(error)}")
    end

    IO.puts("")

    # --- Demo 2: Command with structured input ---
    IO.puts("--- Demo 2: Structured Input ---")
    IO.puts("")

    case SessionManager.run_once(store, adapter, %{command: "uname", args: ["-a"]},
           event_callback: event_callback
         ) do
      {:ok, result} ->
        IO.puts("")
        IO.puts("  Output:    #{String.trim(result.output.content)}")
        IO.puts("  Exit code: #{result.output.exit_code}")

      {:error, error} ->
        IO.puts("  Error: #{inspect(error)}")
    end

    IO.puts("")

    # --- Demo 3: Listing project files ---
    IO.puts("--- Demo 3: Project File Listing ---")
    IO.puts("")

    case SessionManager.run_once(store, adapter, "ls -la mix.exs lib/",
           event_callback: event_callback
         ) do
      {:ok, result} ->
        IO.puts("")
        IO.puts("  Output (first 5 lines):")

        result.output.content
        |> String.split("\n")
        |> Enum.take(5)
        |> Enum.each(fn line -> IO.puts("    #{line}") end)

      {:error, error} ->
        IO.puts("  Error: #{inspect(error)}")
    end

    IO.puts("")

    # --- Demo 4: Non-zero exit code ---
    IO.puts("--- Demo 4: Non-Zero Exit Code ---")
    IO.puts("")

    case SessionManager.run_once(store, adapter, "sh -c 'echo this will fail >&2; exit 42'",
           event_callback: event_callback
         ) do
      {:ok, result} ->
        IO.puts("")
        IO.puts("  Output:    #{String.trim(result.output.content)}")
        IO.puts("  Exit code: #{result.output.exit_code}")

      {:error, error} ->
        IO.puts("  Error: #{inspect(error)}")
    end

    IO.puts("")

    # --- Demo 5: Direct Workspace.Exec usage ---
    IO.puts("--- Demo 5: Direct Workspace.Exec (no SessionManager) ---")
    IO.puts("")

    case Exec.run("date", ["+%Y-%m-%d %H:%M:%S"]) do
      {:ok, result} ->
        IO.puts("  Date:      #{String.trim(result.stdout)}")
        IO.puts("  Exit code: #{result.exit_code}")
        IO.puts("  Duration:  #{result.duration_ms}ms")

      {:error, error} ->
        IO.puts("  Error: #{inspect(error)}")
    end

    :ok
  end

  defp start_provider_adapter("claude"), do: ClaudeAdapter.start_link([])

  defp start_provider_adapter("codex"),
    do: CodexAdapter.start_link(working_directory: File.cwd!())

  defp start_provider_adapter("amp"), do: AmpAdapter.start_link(cwd: File.cwd!())

  defp extract_output_content(output) when is_map(output) do
    content = Map.get(output, :content) || Map.get(output, "content")

    if is_binary(content) and content != "" do
      String.trim(content)
    else
      inspect(output)
    end
  end

  defp extract_output_content(other), do: inspect(other)
end

ShellExec.main(System.argv())
