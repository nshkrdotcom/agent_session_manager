# SDK Integration Notes

This document details the integration points between AgentSessionManager and provider SDKs.

## Overview

AgentSessionManager uses a provider adapter pattern to abstract SDK differences. Each provider implements the `ProviderAdapter` behaviour, translating provider-specific APIs into the normalized event model.

## Provider Adapter Behaviour

```elixir
@behaviour AgentSessionManager.Ports.ProviderAdapter

@callback name(adapter :: GenServer.server()) :: String.t()
@callback capabilities(adapter :: GenServer.server()) :: {:ok, [Capability.t()]} | {:error, Error.t()}
@callback execute(adapter :: GenServer.server(), run :: Run.t(), session :: Session.t(), opts :: keyword()) ::
            {:ok, map()} | {:error, Error.t()}
@callback cancel(adapter :: GenServer.server(), run_id :: String.t()) ::
            {:ok, Run.t()} | {:error, Error.t()}
@callback validate_config(adapter :: GenServer.server(), config :: map()) ::
            :ok | {:error, Error.t()}
```

## Claude SDK Integration (`claude_agent_sdk`)

### SDK Overview

The ClaudeAdapter integrates with `claude_agent_sdk`, which wraps the Claude Code CLI and provides a typed Message stream interface.

**SDK Entry Point**: `ClaudeAgentSDK.Query.run/3`

Returns a stream of `ClaudeAgentSDK.Message` structs.

### Event Mapping

| Claude SDK Message Type | Subtype | Normalized Event | Notes |
|------------------------|---------|------------------|-------|
| `:system` | `:init` | `run_started` | Session initialization with model, tools |
| `:assistant` | - | `message_streamed` | Content deltas from Claude |
| `:assistant` (tool_use) | - | `tool_call_started`, `tool_call_completed` | Tool invocations |
| `:result` | `:success` | `run_completed`, `token_usage_updated` | Final result with usage stats |
| `:result` | `:error_*` | `error_occurred`, `run_failed` | Error conditions |

### Claude SDK Message Shape

#### System Init Message
```elixir
%ClaudeAgentSDK.Message{
  type: :system,
  subtype: :init,
  data: %{
    session_id: "session-abc123",
    cwd: "/working/directory",
    tools: ["Read", "Write", "Bash"],
    mcp_servers: [],
    model: "claude-sonnet-4-20250514",
    permission_mode: "default",
    api_key_source: "env"
  },
  raw: %{}
}
```

#### Assistant Message
```elixir
%ClaudeAgentSDK.Message{
  type: :assistant,
  subtype: nil,
  data: %{
    message: %{
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "Hello! How can I help?"},
        %{"type" => "tool_use", "id" => "toolu_123", "name" => "Read", "input" => %{"path" => "/file.txt"}}
      ]
    },
    session_id: "session-abc123"
  },
  raw: %{}
}
```

#### Result Success Message
```elixir
%ClaudeAgentSDK.Message{
  type: :result,
  subtype: :success,
  data: %{
    session_id: "session-abc123",
    result: "Final response text",
    total_cost_usd: 0.003,
    duration_ms: 2500,
    duration_api_ms: 2100,
    num_turns: 2,
    is_error: false,
    usage: %{"input_tokens" => 150, "output_tokens" => 75}
  },
  raw: %{}
}
```

### Capabilities

| Capability | Type | Description |
|------------|------|-------------|
| `streaming` | `:sampling` | Real-time response streaming |
| `tool_use` | `:tool` | Function/tool calling |
| `vision` | `:resource` | Image understanding |
| `system_prompts` | `:prompt` | System prompt support |
| `interrupt` | `:sampling` | Request cancellation |

### Implementation Notes

1. **Session ID Preservation**: The Claude SDK provides its own session_id which is preserved in session metadata as `provider_session_id`
2. **Tool Handling**: Tool use blocks in assistant messages trigger both `tool_call_started` and `tool_call_completed` events
3. **Cancellation**: Implemented via interrupt signal to the underlying CLI process
4. **Testing**: Use `ClaudeAgentSDKMock` for testing without CLI/network dependencies

## Codex SDK Integration (`codex_sdk`)

### SDK Overview

The CodexAdapter integrates with `codex_sdk`, which provides the OpenAI-compatible Codex/GPT API with thread-based conversations.

**SDK Entry Point**: `Codex.Thread.run_streamed/3`

Returns a `RunResultStreaming` struct with an events stream accessed via `raw_events/1`.

### Event Mapping

| Codex SDK Event | Normalized Event | Notes |
|-----------------|------------------|-------|
| `ThreadStarted` | `run_started` | Thread initialization |
| `TurnStarted` | (internal) | Turn lifecycle |
| `ItemAgentMessageDelta` | `message_streamed` | Content chunks |
| `ToolCallRequested` | `tool_call_started` | Tool invocation begins |
| `ToolCallCompleted` | `tool_call_completed` | Tool result received |
| `ThreadTokenUsageUpdated` | `token_usage_updated` | Usage statistics |
| `TurnCompleted` | `run_completed` | Turn/run finished |
| `TurnFailed` | `run_failed` | Error during turn |
| `TurnAborted` | `run_cancelled` | Cancellation |
| `Error` | `error_occurred` | Error event |

### Codex SDK Event Shapes

#### ThreadStarted
```elixir
%Codex.Events.ThreadStarted{
  thread_id: "thread-xyz789",
  metadata: %{}
}
```

#### ItemAgentMessageDelta
```elixir
%Codex.Events.ItemAgentMessageDelta{
  thread_id: "thread-xyz789",
  turn_id: "turn-001",
  item: %{
    "id" => "item-1",
    "type" => "agentMessage",
    "content" => [%{"type" => "text", "text" => "Partial content..."}]
  }
}
```

#### ToolCallRequested
```elixir
%Codex.Events.ToolCallRequested{
  thread_id: "thread-xyz789",
  turn_id: "turn-001",
  call_id: "call-123",
  tool_name: "read_file",
  arguments: %{"path" => "/test.txt"},
  requires_approval: false
}
```

#### TurnCompleted
```elixir
%Codex.Events.TurnCompleted{
  thread_id: "thread-xyz789",
  turn_id: "turn-001",
  status: "completed",
  usage: %{"input_tokens" => 50, "output_tokens" => 25}
}
```

### Capabilities

| Capability | Type | Description |
|------------|------|-------------|
| `streaming` | `:sampling` | Response streaming |
| `tool_use` | `:tool` | Function calling |
| `interrupt` | `:sampling` | Request cancellation |
| `mcp` | `:tool` | MCP server support |
| `file_operations` | `:tool` | File read/write |
| `bash` | `:tool` | Shell execution |

### Implementation Notes

1. **Thread ID Preservation**: The Codex SDK thread_id is preserved in session metadata as `provider_session_id`
2. **Cancellation**: Implemented via `RunResultStreaming.cancel/1`
3. **Testing**: Use `CodexMockSDK` for testing without network dependencies

## Provider Metadata

Both adapters preserve provider-specific metadata in session and run records:

```elixir
# Session metadata after execution
session.metadata = %{
  provider: "claude",           # or "codex"
  provider_session_id: "...",   # Claude's session_id or Codex's thread_id
  model: "claude-sonnet-4-20250514"
}

# Run metadata
run.metadata = %{
  provider: "claude",
  provider_session_id: "...",
  model: "claude-sonnet-4-20250514"
}
```

## Telemetry Integration

Adapter events are automatically emitted to telemetry:

```elixir
# Event namespace: [:agent_session_manager, :adapter, event_type]
# Example: [:agent_session_manager, :adapter, :message_streamed]

:telemetry.attach(
  "my-handler",
  [:agent_session_manager, :adapter, :message_streamed],
  fn _event, measurements, metadata, _config ->
    # measurements: %{system_time: ..., input_tokens: ..., output_tokens: ...}
    # metadata: %{run_id: ..., session_id: ..., provider: :claude, ...}
  end,
  nil
)
```

## Error Handling

### Provider Errors

Errors from providers are normalized to `AgentSessionManager.Core.Error`:

```elixir
Error.new(:provider_error, "Execution failed",
  provider_error: %{
    original_error: error_details
  }
)
```

### Error Categories

| Code | Description | Recovery |
|------|-------------|----------|
| `:provider_error` | Generic provider error | Check error details |
| `:cancelled` | Operation cancelled | Expected, no recovery needed |
| `:run_not_found` | Unknown run ID | Check run exists |
| `:validation_error` | Config validation failed | Fix configuration |

## Configuration

### Environment Variables

| Provider | Variable | Description |
|----------|----------|-------------|
| Claude | `ANTHROPIC_API_KEY` | API key for Claude |
| Codex | `OPENAI_API_KEY` | API key for OpenAI/Codex |

### Adapter Options

```elixir
# Claude Adapter
{:ok, adapter} = ClaudeAdapter.start_link(
  api_key: "sk-ant-...",
  working_directory: "/path/to/project",
  # For testing:
  sdk_module: ClaudeAgentSDKMock,
  sdk_pid: mock_pid
)

# Codex Adapter
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: "/path/to/project",
  model: "claude-sonnet-4-20250514",
  # For testing:
  sdk_module: CodexMockSDK,
  sdk_pid: mock_pid
)
```

## Testing SDK Integration

### Claude Mock SDK Usage

```elixir
# Start mock with scenario
{:ok, mock} = ClaudeAgentSDKMock.start_link(scenario: :simple_response)

# Or with custom content
{:ok, mock} = ClaudeAgentSDKMock.start_link(
  scenario: :simple_response,
  content: "Custom response",
  session_id: "test-session-123"
)

# Configure adapter to use mock
{:ok, adapter} = ClaudeAdapter.start_link(
  api_key: "test-key",
  sdk_module: ClaudeAgentSDKMock,
  sdk_pid: mock
)
```

### Codex Mock SDK Usage

```elixir
# Start mock with scenario
{:ok, mock} = CodexMockSDK.start_link(scenario: :simple_response)

# Or with tool call scenario
{:ok, mock} = CodexMockSDK.start_link(
  scenario: :with_tool_call,
  tool_name: "read_file",
  tool_args: %{"path" => "/test.txt"}
)

# Configure adapter to use mock
{:ok, adapter} = CodexAdapter.start_link(
  working_directory: "/tmp",
  sdk_module: CodexMockSDK,
  sdk_pid: mock
)
```

### Available Mock Scenarios

**Claude SDK Mock**:
- `:simple_response` - Basic assistant response with success result
- `:streaming` - Multiple assistant messages (chunked content)
- `:with_tool_use` - Tool invocation with result
- `:error` - Error result

**Codex SDK Mock**:
- `:simple_response` - Basic turn completion
- `:streaming` - Multiple delta events
- `:with_tool_call` - Tool request and completion
- `:error` - Error and TurnFailed events
- `:cancelled` - TurnAborted event

## Best Practices

1. **Always check capabilities** before session creation
2. **Handle streaming errors** with proper cleanup
3. **Track token usage** for cost management
4. **Use provider metadata** for debugging and correlation
5. **Monitor telemetry events** for observability
6. **Use mock mode** in CI/CD pipelines - never make real API calls in tests
