# Provider Adapters

Provider adapters are the bridge between AgentSessionManager's core logic and external AI providers. Each adapter implements the `ProviderAdapter` behaviour, translating provider-specific APIs into the normalized interface the rest of the system expects.

## Built-In Adapters

### ClaudeAdapter (Anthropic)

The Claude adapter integrates with Anthropic's API via the ClaudeAgentSDK.

```elixir
{:ok, adapter} = AgentSessionManager.Adapters.ClaudeAdapter.start_link(
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-haiku-4-5-20251001"  # optional, this is the default
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
  model: "gpt-4"  # optional
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
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout + 5_000)
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
    {:ok, %{
      api_key: Keyword.fetch!(opts, :api_key),
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
    # Spawn a worker so we don't block the GenServer
    parent = self()
    spawn_link(fn ->
      result = do_execute(state, run, session, opts)
      GenServer.reply(from, result)
    end)
    {:noreply, state}
  end

  def handle_call({:cancel, _run_id}, _from, state) do
    # Implement cancellation logic
    {:reply, {:ok, "cancelled"}, state}
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
    emit(callback, run, session, :run_completed, %{stop_reason: "end_turn"})

    {:ok, %{
      output: %{content: content, stop_reason: "end_turn", tool_calls: []},
      token_usage: %{input_tokens: 10, output_tokens: 20},
      events: []
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
end
```

## Adapter Execution Model

Both built-in adapters use the same execution model:

1. `execute/4` is called on the GenServer
2. The GenServer spawns a linked worker process
3. The worker performs the actual API call and event streaming
4. The worker sends completion back via `GenServer.cast`
5. The GenServer replies to the original caller

This design allows:
- Multiple concurrent executions through one adapter process
- Cancellation via messages to the worker process
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
```

See [Testing](testing.md) for more on testing patterns.
