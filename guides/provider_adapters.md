# Provider Adapters

Provider adapters are the bridge between AgentSessionManager's core logic and external AI providers. Each adapter implements the `ProviderAdapter` behaviour, translating provider-specific APIs into the normalized interface the rest of the system expects.

## Canonical Tool Event Payloads

Across all built-in adapters, tool call events now include canonical keys:

- `tool_call_id`
- `tool_name`
- `tool_input` (for `:tool_call_started`, and when available on completion/failure)
- `tool_output` (for `:tool_call_completed` / `:tool_call_failed`)

## Built-In Adapters

### ClaudeAdapter (Anthropic)

The Claude adapter integrates with Anthropic's API via the ClaudeAgentSDK.

```elixir
{:ok, adapter} = AgentSessionManager.Adapters.ClaudeAdapter.start_link(
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-haiku-4-5-20251001",  # optional, this is the default
  permission_mode: :full_auto,          # optional, see Permission Modes below
  max_turns: nil,                       # optional, nil = unlimited (default)
  system_prompt: "You are a helpful assistant.",  # optional
  sdk_opts: [verbose: true]             # optional, see SDK Options Passthrough below
)
```

**Capabilities advertised:**
- `streaming` (`:sampling`) -- real-time response streaming
- `tool_use` (`:tool`) -- function/tool calling
- `vision` (`:resource`) -- image understanding
- `system_prompts` (`:prompt`) -- system prompt support
- `interrupt` (`:sampling`) -- cancel in-progress requests

**Event mapping from Claude Streaming API:**

| Streaming Event | Normalized Event |
|---|---|
| `message_start` | `:run_started` |
| `text_delta` | `:message_streamed` |
| `tool_use_start` | `:tool_call_started` |
| `message_delta` | `:token_usage_updated` |
| `message_stop` | `:message_received`, `:run_completed` |

### CodexAdapter

The Codex adapter integrates with the Codex CLI SDK.

```elixir
{:ok, adapter} = AgentSessionManager.Adapters.CodexAdapter.start_link(
  working_directory: File.cwd!(),
  model: "gpt-5.3-codex",      # optional, this is the SDK default
  permission_mode: :full_auto,  # optional, see Permission Modes below
  max_turns: 20,                # optional, nil = SDK default of 10
  system_prompt: "You are a code reviewer.",  # optional, maps to base_instructions
  sdk_opts: [web_search_mode: :live]          # optional, see SDK Options Passthrough below
)
```

**Capabilities advertised:**
- `streaming` (`:sampling`) -- real-time response streaming
- `tool_use` (`:tool`) -- tool calling
- `interrupt` (`:sampling`) -- cancel in-progress requests
- `mcp` (`:tool`) -- MCP server integration
- `file_operations` (`:tool`) -- file read/write
- `bash` (`:tool`) -- command execution

**Event mapping from Codex SDK:**

| Codex SDK Event | Normalized Event |
|---|---|
| `ThreadStarted` | `:run_started` |
| `ItemAgentMessageDelta` | `:message_streamed` |
| `ThreadTokenUsageUpdated` | `:token_usage_updated` |
| `ToolCallRequested` | `:tool_call_started` |
| `ToolCallCompleted` | `:tool_call_completed` |
| `TurnCompleted` | `:message_received`, `:run_completed` |
| `TurnFailed` / `Error` | `:error_occurred`, `:run_failed` |

### AmpAdapter (Sourcegraph)

The Amp adapter integrates with the Sourcegraph Amp API via the Amp SDK.

```elixir
{:ok, adapter} = AgentSessionManager.Adapters.AmpAdapter.start_link(
  cwd: File.cwd!(),
  permission_mode: :full_auto,  # optional, see Permission Modes below
  sdk_opts: [visibility: "private", stream_timeout_ms: 600_000]  # optional
)
```

**Capabilities advertised:**
- `streaming` (`:sampling`) -- real-time response streaming
- `tool_use` (`:tool`) -- tool calling
- `interrupt` (`:sampling`) -- cancel in-progress requests
- `mcp` (`:tool`) -- MCP server integration
- `bash` (`:tool`) -- command execution
- `file_operations` (`:tool`) -- file read/write

**Event mapping from Amp SDK:**

| Amp SDK Event | Normalized Event |
|---|---|
| `SystemMessage` | `:run_started` |
| `AssistantMessage` (text) | `:message_streamed`, `:message_received` |
| `AssistantMessage` (tool use) | `:tool_call_started` |
| `ResultMessage` | `:tool_call_completed`, `:run_completed` |
| `ErrorResultMessage` | `:tool_call_failed`, `:run_failed` |

## Permission Modes

All built-in adapters accept an optional `:permission_mode` on `start_link`. This controls how each provider handles tool-call approvals and sandboxing.

The `AgentSessionManager.PermissionMode` module defines five normalized modes:

| Mode | Description |
|---|---|
| `:default` | Provider's default permission handling |
| `:accept_edits` | Auto-accept file edit operations (Claude-specific; no-op on Codex/Amp) |
| `:plan` | Plan mode -- generate a plan before executing (Claude-specific; no-op on Codex/Amp) |
| `:full_auto` | Skip all permission prompts, allow all tool calls |
| `:dangerously_skip_permissions` | Bypass all approvals and sandboxing (most permissive) |

Each adapter maps these to its provider SDK's native semantics:

| Normalized Mode | Claude SDK | Codex SDK | Amp SDK |
|---|---|---|---|
| `:default` | (omitted) | (defaults) | (defaults) |
| `:accept_edits` | `permission_mode: :accept_edits` | no-op | no-op |
| `:plan` | `permission_mode: :plan` | no-op | no-op |
| `:full_auto` | `permission_mode: :bypass_permissions` | `full_auto: true` | `dangerously_allow_all: true` |
| `:dangerously_skip_permissions` | `permission_mode: :bypass_permissions` | `dangerously_bypass_approvals_and_sandbox: true` | `dangerously_allow_all: true` |

```elixir
# Claude: bypass all permission prompts
{:ok, adapter} = ClaudeAdapter.start_link(permission_mode: :full_auto)

# Codex: enable full auto mode
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: File.cwd!(),
  permission_mode: :full_auto
)

# Amp: allow all dangerous operations
{:ok, adapter} = AmpAdapter.start_link(
  cwd: File.cwd!(),
  permission_mode: :dangerously_skip_permissions
)
```

## Max Turns

All adapters accept an optional `:max_turns` to control the agentic loop turn limit. Each provider handles this differently:

| Provider | Default | Behavior |
|---|---|---|
| Claude | `nil` (unlimited) | Omits `--max-turns` flag, allowing the CLI to run unlimited tool-use turns |
| Codex | `nil` (SDK default: 10) | When set, overrides the SDK's default 10-turn limit |
| Amp | N/A | Ignored -- turn limits are CLI-enforced and not configurable via SDK |

```elixir
# Claude: unlimited turns (default)
{:ok, adapter} = ClaudeAdapter.start_link(max_turns: nil)

# Claude: limit to 5 turns
{:ok, adapter} = ClaudeAdapter.start_link(max_turns: 5)

# Codex: override SDK default of 10
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: File.cwd!(),
  max_turns: 25
)
```

## System Prompt

All adapters accept an optional `:system_prompt`. The mapping varies by provider:

| Provider | Maps to | Notes |
|---|---|---|
| Claude | `system_prompt` on `ClaudeAgentSDK.Options` | Passed directly |
| Codex | `base_instructions` on `Codex.Thread.Options` | Codex-specific name |
| Amp | Stored in state | No direct SDK equivalent |

```elixir
{:ok, adapter} = ClaudeAdapter.start_link(
  system_prompt: "You are a code reviewer. Focus on security issues."
)

{:ok, adapter} = CodexAdapter.start_link(
  working_directory: File.cwd!(),
  system_prompt: "You are a code reviewer."  # maps to base_instructions
)
```

## SDK Options Passthrough

For provider-specific SDK options not covered by the normalized interface, all adapters accept `:sdk_opts` -- a keyword list of fields to merge into the underlying SDK options struct.

**Precedence:** sdk_opts are applied first, then normalized options (`:permission_mode`, `:max_turns`, etc.) are applied on top. This means normalized options always take precedence.

```elixir
# Claude: pass through arbitrary ClaudeAgentSDK.Options fields
{:ok, adapter} = ClaudeAdapter.start_link(
  permission_mode: :full_auto,
  sdk_opts: [
    verbose: true,
    max_budget_usd: 1.0,
    mcp_servers: %{"my-server" => %{command: "npx", args: ["-y", "my-mcp"]}},
    add_dirs: ["/path/to/other/repo"],
    setting_sources: ["user", "project"]
  ]
)

# Codex: pass through arbitrary Codex.Thread.Options fields
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: File.cwd!(),
  sdk_opts: [
    web_search_mode: :live,
    additional_directories: ["/other/path"],
    show_raw_agent_reasoning: true
  ]
)

# Amp: pass through arbitrary AmpSdk.Types.Options fields
{:ok, adapter} = AmpAdapter.start_link(
  cwd: File.cwd!(),
  sdk_opts: [
    visibility: "private",
    labels: ["batch-run", "v2"],
    stream_timeout_ms: 600_000,
    env: %{"MY_VAR" => "value"}
  ]
)
```

Only fields that exist on the underlying SDK options struct are applied; unknown keys are ignored.

## The ProviderAdapter Behaviour

All adapters must implement these callbacks:

```elixir
@callback name(adapter) :: String.t()
@callback capabilities(adapter) :: {:ok, [Capability.t()]} | {:error, Error.t()}
@callback execute(adapter, Run.t(), Session.t(), opts) :: {:ok, result} | {:error, Error.t()}
@callback cancel(adapter, run_id :: String.t()) :: {:ok, String.t()} | {:error, Error.t()}
@callback validate_config(adapter, config :: map()) :: :ok | {:error, Error.t()}
```

### `name/1`

Returns a string identifying the provider (e.g., `"claude"`, `"codex"`). Used for logging and metadata.

### `capabilities/1`

Returns the list of capabilities this provider supports. The `SessionManager` uses this for capability negotiation before starting runs.

### `execute/4`

The main execution function. It receives a run, session, and options (including `:event_callback` and `:timeout`). The adapter should:

1. Emit `:run_started`
2. Send the request to the provider
3. Emit events as the response streams in
4. Emit `:run_completed` or `:run_failed`
5. Return `{:ok, %{output: ..., token_usage: ..., events: ...}}`

`events` should contain the emitted event sequence for that execution (not an empty placeholder list).

### `cancel/2`

Attempts to cancel an in-progress run. Should emit `:run_cancelled` on success.

### `validate_config/2`

Validates provider-specific configuration before startup.

## Writing Your Own Adapter

Here's a skeleton for a custom adapter:

```elixir
defmodule MyApp.Adapters.CustomAdapter do
  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.ProviderAdapter

  # -- Public API --

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, opts, name: name),
    else: GenServer.start_link(__MODULE__, opts)
  end

  # -- ProviderAdapter callbacks --

  @impl true
  def name(_adapter), do: "custom"

  @impl true
  def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

  @impl true
  def execute(adapter, run, session, opts \\ []) do
    timeout = ProviderAdapter.resolve_execute_timeout(opts)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout)
  end

  @impl true
  def cancel(adapter, run_id), do: GenServer.call(adapter, {:cancel, run_id})

  @impl true
  def validate_config(_adapter, config) do
    if Map.has_key?(config, :api_key), do: :ok,
    else: {:error, Error.new(:validation_error, "api_key is required")}
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, %{
      api_key: Keyword.fetch!(opts, :api_key),
      task_supervisor: task_supervisor,
      run_refs: %{},      # task_ref => GenServer.from()
      active_runs: %{},   # run_id => task_ref
      capabilities: [
        %Capability{name: "streaming", type: :sampling, enabled: true,
                     description: "Real-time streaming"}
      ]
    }}
  end

  @impl GenServer
  def handle_call(:capabilities, _from, state) do
    {:reply, {:ok, state.capabilities}, state}
  end

  def handle_call({:execute, run, session, opts}, from, state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        do_execute(state, run, session, opts)
      end)

    new_state = %{
      state
      | run_refs: Map.put(state.run_refs, task.ref, from),
        active_runs: Map.put(state.active_runs, run.id, task.ref)
    }

    {:noreply, new_state}
  end

  def handle_call({:cancel, run_id}, _from, state) do
    case Map.fetch(state.active_runs, run_id) do
      {:ok, _task_ref} ->
        # Implement provider-specific cancellation logic here.
        {:reply, {:ok, run_id}, state}

      :error ->
        {:reply, {:error, Error.new(:run_not_found, "Run not found: #{run_id}")}, state}
    end
  end

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.run_refs, task_ref) do
      {nil, _run_refs} ->
        {:noreply, state}

      {from, run_refs} ->
        Process.demonitor(task_ref, [:flush])
        GenServer.reply(from, result)
        active_runs = remove_task_ref(state.active_runs, task_ref)
        {:noreply, %{state | run_refs: run_refs, active_runs: active_runs}}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.run_refs, task_ref) do
      {nil, _run_refs} ->
        {:noreply, state}

      {from, run_refs} ->
        error = Error.new(:internal_error, "Execution task failed: #{inspect(reason)}")
        GenServer.reply(from, {:error, error})
        active_runs = remove_task_ref(state.active_runs, task_ref)
        {:noreply, %{state | run_refs: run_refs, active_runs: active_runs}}
    end
  end

  defp do_execute(state, run, session, opts) do
    callback = Keyword.get(opts, :event_callback)

    # Emit run_started
    emit(callback, run, session, :run_started, %{})

    # Call your provider API here...
    content = "Hello from custom provider!"

    # Emit streaming events
    emit(callback, run, session, :message_streamed, %{delta: content, content: content})

    # Emit completion
    emit(callback, run, session, :message_received, %{content: content, role: "assistant"})
    emit(callback, run, session, :run_completed, %{
      stop_reason: "end_turn",
      token_usage: %{input_tokens: 10, output_tokens: 20}
    })

    {:ok, %{
      output: %{content: content, stop_reason: "end_turn", tool_calls: []},
      token_usage: %{input_tokens: 10, output_tokens: 20},
      events: [%{type: :run_started}, %{type: :message_received}, %{type: :run_completed}]
    }}
  end

  defp emit(nil, _, _, _, _), do: :ok
  defp emit(callback, run, session, type, data) do
    callback.(%{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: session.id,
      run_id: run.id,
      data: data,
      provider: :custom
    })
  end

  defp remove_task_ref(active_runs, task_ref) do
    active_runs
    |> Enum.reject(fn {_run_id, ref} -> ref == task_ref end)
    |> Map.new()
  end
end
```

## Adapter Execution Model

All three built-in adapters use the same execution model:

1. `execute/4` is called on the GenServer
2. The GenServer starts a supervised **nolink** task (`Task.Supervisor.async_nolink/2`)
3. The task performs the actual API call and event streaming
4. The GenServer handles task result and `:DOWN` messages for deterministic reply + cleanup
5. Cancellation marks run state and forwards provider-specific cancel signals to the active task/stream

This design allows:
- Multiple concurrent executions through one adapter process
- Cancellation via messages/signals to the task/stream
- The GenServer to remain responsive during long-running executions

## Testing with Mock Adapters

For testing, you can inject mock SDK modules into the adapters:

```elixir
# ClaudeAdapter accepts :sdk_module and :sdk_pid for testing
{:ok, adapter} = ClaudeAdapter.start_link(
  api_key: "test-key",
  sdk_module: MyMockSDK,
  sdk_pid: mock_pid
)

# CodexAdapter similarly accepts :sdk_module and :sdk_pid
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: "/tmp",
  sdk_module: MyMockCodexSDK,
  sdk_pid: mock_pid
)

# AmpAdapter accepts :sdk_module and :sdk_pid
{:ok, adapter} = AmpAdapter.start_link(
  api_key: "test-key",
  sdk_module: MyMockAmpSDK,
  sdk_pid: mock_pid
)
```

See [Testing](testing.md) for more on testing patterns.
