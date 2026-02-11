# Shell Runner

The Shell Runner enables shell command execution as a first-class citizen in AgentSessionManager.
It provides two complementary modules:

## Workspace.Exec -- Low-Level Command Execution

`AgentSessionManager.Workspace.Exec` provides direct command execution with timeout,
output capture, and streaming. Use it when you need lightweight command execution
without session management overhead.

### Basic Usage

    {:ok, result} = AgentSessionManager.Workspace.Exec.run("mix", ["test"])
    IO.puts("Exit code: #{result.exit_code}")
    IO.puts("Output: #{result.stdout}")

### With Options

    {:ok, result} = AgentSessionManager.Workspace.Exec.run(
      "npm", ["run", "build"],
      cwd: "/home/user/project",
      timeout_ms: 120_000,
      env: [{"NODE_ENV", "production"}]
    )

### Streaming

    AgentSessionManager.Workspace.Exec.run_streaming("mix", ["test", "--trace"])
    |> Enum.each(fn
      {:stdout, data} -> IO.write(data)
      {:exit, code} -> IO.puts("\nExit: #{code}")
      {:error, reason} -> IO.puts(:stderr, "Error: #{inspect(reason)}")
    end)

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:cwd` | `String.t()` | `File.cwd!()` | Working directory |
| `:timeout_ms` | `pos_integer()` | `30_000` | Command timeout |
| `:max_output_bytes` | `pos_integer()` | `1_048_576` | Output size limit |
| `:env` | `[{String.t(), String.t()}]` | `[]` | Environment variables |
| `:on_output` | `(chunk -> any())` | `nil` | Callback for streaming output |

## ShellAdapter -- Managed Execution via SessionManager

`AgentSessionManager.Adapters.ShellAdapter` implements the `ProviderAdapter` behaviour,
enabling shell commands to participate in the full SessionManager lifecycle: event emission,
policy enforcement, workspace snapshots, concurrency control, and persistence.

### Basic Usage

    alias AgentSessionManager.Adapters.{ShellAdapter, InMemorySessionStore}
    alias AgentSessionManager.SessionManager

    {:ok, store} = InMemorySessionStore.start_link([])
    {:ok, adapter} = ShellAdapter.start_link(cwd: File.cwd!())

    {:ok, result} = SessionManager.run_once(store, adapter, "mix test",
      event_callback: fn event ->
        case event.type do
          :message_streamed -> IO.write(event.data.delta)
          :run_completed -> IO.puts("\nDone")
          _ -> :ok
        end
      end
    )

### Input Formats

ShellAdapter accepts three input formats:

    # String -- executed via /bin/sh -c
    "mix test --cover"

    # Structured map -- explicit command and args
    %{command: "mix", args: ["test", "--cover"], cwd: "/path", timeout_ms: 60_000}

    # Messages (compatibility) -- extracts user content as command
    %{messages: [%{role: "user", content: "mix test"}]}

### Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:cwd` | `String.t()` | **required** | Working directory |
| `:timeout_ms` | `pos_integer()` | `30_000` | Default command timeout |
| `:max_output_bytes` | `pos_integer()` | `1_048_576` | Max output capture size |
| `:env` | `[{String.t(), String.t()}]` | `[]` | Environment variables |
| `:shell` | `String.t()` | `"/bin/sh"` | Shell for string commands |
| `:allowed_commands` | `[String.t()]` | `nil` | Allowlist (nil = all) |
| `:denied_commands` | `[String.t()]` | `nil` | Denylist of blocked commands |
| `:success_exit_codes` | `[integer()]` | `[0]` | Exit codes treated as success |

### Event Mapping

| Shell Event | Normalized Event | Notes |
|-------------|-----------------|-------|
| Command started | `:run_started` | Execution begins |
| Command started | `:tool_call_started` | tool_name: "bash" |
| Command completed (exit 0) | `:tool_call_completed` | |
| Command failed (exit != 0) | `:tool_call_failed` | |
| Full output | `:message_received` | Complete stdout |
| Success | `:run_completed` | stop_reason: "exit_code_0" |
| Failure | `:run_failed` | error_code: :command_failed |
| Timeout | `:run_failed` | error_code: :command_timeout |
| Cancelled | `:run_cancelled` | |

### Security

Use `allowed_commands` and `denied_commands` to restrict which commands can be executed:

    {:ok, adapter} = ShellAdapter.start_link(
      cwd: File.cwd!(),
      allowed_commands: ["mix", "npm", "git"],
      denied_commands: ["rm", "sudo", "chmod"]
    )

The denylist takes precedence over the allowlist. Both match against the base name
of the executable.

### Mixed AI + Shell Workflows

ShellAdapter enables mixed workflows where AI and shell runs participate in the
same session lifecycle:

    {:ok, claude} = ClaudeAdapter.start_link([])
    {:ok, shell} = ShellAdapter.start_link(cwd: File.cwd!())

    # Step 1: Ask AI to generate code
    {:ok, _} = SessionManager.run_once(store, claude, "Write a test")

    # Step 2: Run the tests
    {:ok, test_result} = SessionManager.run_once(store, shell, "mix test")

    # Step 3: If tests fail, ask AI to fix
    if test_result.output.exit_code != 0 do
      SessionManager.run_once(store, claude,
        "Tests failed: #{test_result.output.content}\nPlease fix.")
    end
