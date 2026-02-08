defmodule AmpDirect do
  @moduledoc false

  # Demonstrates Amp SDK unique features accessed directly via AmpSdk.
  #
  # Sections:
  #   threads     - Thread management (list, create, export)
  #   permissions - Permission management
  #   mcp         - MCP server configuration and status
  #   modes       - Execution in different modes (smart, rush, deep)
  #   all         - Run all sections (default)

  alias AmpSdk.Types.{
    ErrorResultMessage,
    MCPServer,
    Options,
    PermissionRule,
    ResultMessage,
    ThreadSummary
  }

  @sections ~w(threads permissions mcp modes all)

  # ============================================================================
  # Entry Point
  # ============================================================================

  def main(args) do
    section = parse_args(args)
    print_header(section)

    case check_auth() do
      :ok ->
        case run_sections(section) do
          :ok ->
            print_success("Amp direct example completed successfully!")
            System.halt(0)

          {:error, error} ->
            print_error("Example failed: #{format_error(error)}")
            System.halt(1)
        end

      {:error, reason} ->
        print_error("Authentication check failed: #{reason}")
        print_auth_instructions()
        System.halt(1)
    end
  end

  # ============================================================================
  # Command Line Argument Parsing
  # ============================================================================

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [section: :string, help: :boolean],
        aliases: [s: :section, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    section = opts[:section] || "all"

    unless section in @sections do
      print_error("Unknown section: #{section}")
      print_usage()
      System.halt(1)
    end

    section
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/amp_direct.exs [options]

    Options:
      --section, -s <name>  Section to run (#{Enum.join(@sections, ", ")}). Default: all
      --help, -h            Show this help message

    Authentication:
      Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/amp_direct.exs
      mix run examples/amp_direct.exs --section threads
      mix run examples/amp_direct.exs --section permissions
      mix run examples/amp_direct.exs --section mcp
      mix run examples/amp_direct.exs --section modes
    """)
  end

  # ============================================================================
  # Authentication Check
  # ============================================================================

  defp check_auth do
    case System.find_executable("amp") do
      nil ->
        {:error, "amp CLI not found in PATH"}

      _path ->
        :ok
    end
  end

  defp print_auth_instructions do
    IO.puts("""

    To authenticate with Amp:

    1. Install the Amp CLI from https://sourcegraph.com/amp
    2. Run `amp login` to authenticate via browser
    3. Or set AMP_API_KEY environment variable
    """)
  end

  # ============================================================================
  # Section Router
  # ============================================================================

  defp run_sections("all") do
    sections = @sections -- ["all"]

    Enum.reduce_while(sections, :ok, fn section, :ok ->
      case run_section(section) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp run_sections(section), do: run_section(section)

  # ============================================================================
  # Section: Threads
  # ============================================================================

  defp run_section("threads") do
    print_section("Threads")

    print_step("Listing threads")

    case AmpSdk.threads_list() do
      {:ok, threads} ->
        print_thread_summaries(threads)

      {:error, reason} ->
        IO.puts("  Thread listing not available: #{inspect(reason)}")
    end

    print_step("Creating a new thread")

    case AmpSdk.threads_new(title: "SDK Test Thread") do
      {:ok, thread_id} ->
        IO.puts("  Created thread: #{thread_id}")

        print_step("Exporting thread as markdown")

        case AmpSdk.threads_markdown(thread_id) do
          {:ok, markdown} ->
            preview = String.slice(markdown, 0, 200)
            IO.puts("  Markdown preview: #{preview}...")

          {:error, reason} ->
            IO.puts("  Export not available: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("  Thread creation not available: #{inspect(reason)}")
    end

    :ok
  end

  # ============================================================================
  # Section: Permissions
  # ============================================================================

  defp run_section("permissions") do
    print_section("Permissions")

    print_step("Listing current permissions")

    case AmpSdk.permissions_list() do
      {:ok, rules} ->
        print_permission_rules(rules)

      {:error, reason} ->
        IO.puts("  Permission listing not available: #{inspect(reason)}")
    end

    print_step("Creating a permission rule")

    permission = AmpSdk.create_permission("Read", "allow", context: "workspace")
    IO.puts("  Created permission: #{inspect(permission)}")

    :ok
  end

  # ============================================================================
  # Section: MCP
  # ============================================================================

  defp run_section("mcp") do
    print_section("MCP Server Configuration")

    print_step("Listing configured MCP servers")

    case AmpSdk.mcp_list() do
      {:ok, servers} ->
        print_mcp_servers(servers)

      {:error, reason} ->
        IO.puts("  MCP listing not available: #{inspect(reason)}")
    end

    print_step("Running MCP diagnostics")

    case AmpSdk.mcp_doctor() do
      {:ok, result} ->
        print_text_output("MCP doctor", result, max_lines: 10)

      {:error, reason} ->
        IO.puts("  MCP doctor not available: #{inspect(reason)}")
    end

    :ok
  end

  # ============================================================================
  # Section: Modes
  # ============================================================================

  defp run_section("modes") do
    print_section("Execution Modes")

    modes = ["smart", "rush"]

    Enum.each(modes, fn mode ->
      print_step("Executing in #{mode} mode")

      options = %Options{
        cwd: File.cwd!(),
        mode: mode,
        thinking: false
      }

      prompt = "What is 2 + 2? Reply with just the number."

      stream = AmpSdk.execute(prompt, options)

      result =
        Enum.reduce(stream, nil, fn
          %ResultMessage{result: result}, _acc ->
            {:ok, result}

          %ErrorResultMessage{error: error}, _acc ->
            {:error, error}

          msg, acc ->
            if msg.type == "assistant" do
              IO.write(".")
            end

            acc
        end)

      IO.puts("")

      case result do
        {:ok, text} ->
          IO.puts("  Result (#{mode}): #{String.trim(text)}")

        {:error, error} ->
          IO.puts("  Error (#{mode}): #{error}")

        nil ->
          IO.puts("  No result received (#{mode})")
      end
    end)

    :ok
  end

  # ============================================================================
  # Output Formatting
  # ============================================================================

  defp print_header(section) do
    IO.puts("")

    IO.puts(IO.ANSI.bright() <> "AgentSessionManager - Amp Direct Features" <> IO.ANSI.reset())

    IO.puts(String.duplicate("=", 50))
    IO.puts("Section: #{section}")
    IO.puts(String.duplicate("=", 50))
    IO.puts("")
  end

  defp print_section(name) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.blue() <> "#{name}" <> IO.ANSI.reset())
    IO.puts(String.duplicate("-", 40))
  end

  defp print_step(description) do
    IO.puts("")
    IO.puts(IO.ANSI.green() <> "  [STEP] " <> IO.ANSI.reset() <> description)
  end

  defp print_error(message) do
    IO.puts(IO.ANSI.red() <> "  [ERROR] " <> IO.ANSI.reset() <> message)
  end

  defp print_success(message) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.green() <> message <> IO.ANSI.reset())
    IO.puts("")
  end

  defp print_thread_summaries(threads) when is_list(threads) do
    IO.puts("  Found #{length(threads)} thread(s)")

    threads
    |> Enum.take(5)
    |> Enum.each(fn
      %ThreadSummary{} = thread ->
        IO.puts(
          "    - #{thread.id} | #{thread.visibility} | messages=#{thread.messages} | #{thread.last_updated} | #{thread.title}"
        )

      other ->
        IO.puts("    - #{inspect(other)}")
    end)
  end

  defp print_permission_rules(rules) when is_list(rules) do
    IO.puts("  Found #{length(rules)} permission rule(s)")

    rules
    |> Enum.take(20)
    |> Enum.each(fn
      %PermissionRule{} = rule ->
        context =
          case rule.context do
            nil -> ""
            value -> " (context=#{value})"
          end

        IO.puts("    - #{rule.action} #{rule.tool}#{context}")

      other ->
        IO.puts("    - #{inspect(other)}")
    end)
  end

  defp print_mcp_servers(servers) when is_list(servers) do
    IO.puts("  Found #{length(servers)} MCP server(s)")

    servers
    |> Enum.take(20)
    |> Enum.each(fn
      %MCPServer{} = server ->
        detail =
          cond do
            is_binary(server.url) -> "url=#{server.url}"
            is_binary(server.command) -> "command=#{server.command}"
            true -> "details=none"
          end

        IO.puts("    - #{server.name} [#{server.type}] source=#{server.source} #{detail}")

      other ->
        IO.puts("    - #{inspect(other)}")
    end)
  end

  defp print_text_output(label, output, opts) when is_binary(output) do
    max_lines = Keyword.get(opts, :max_lines, 8)

    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    IO.puts("  #{label}: #{length(lines)} line(s)")

    lines
    |> Enum.take(max_lines)
    |> Enum.each(fn line ->
      IO.puts("    #{line}")
    end)

    if length(lines) > max_lines do
      IO.puts("    ...")
    end
  end

  defp print_text_output(label, value, _opts) do
    IO.puts("  #{label}: #{inspect(value)}")
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end

AmpDirect.main(System.argv())
