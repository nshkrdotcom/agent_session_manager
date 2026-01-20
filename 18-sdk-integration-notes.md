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

## Claude (Anthropic) Integration

### API Overview

Claude uses the Messages API with Server-Sent Events (SSE) for streaming.

**Endpoint**: `POST https://api.anthropic.com/v1/messages`

**Headers**:
```
x-api-key: {ANTHROPIC_API_KEY}
anthropic-version: 2023-06-01
content-type: application/json
```

### Event Mapping

| Claude API Event | Normalized Event | Notes |
|------------------|------------------|-------|
| `message_start` | `run_started` | Contains initial usage stats |
| `content_block_start` | (internal) | Tracks content block type |
| `content_block_delta` | `message_streamed` | Text deltas |
| `content_block_delta` (tool_use) | (internal) | Accumulates JSON input |
| `content_block_stop` | `tool_call_completed` | For tool_use blocks |
| `message_delta` | `token_usage_updated` | Final usage stats |
| `message_stop` | `message_received`, `run_completed` | Final events |

### Claude Event Shapes

#### message_start
```json
{
  "type": "message_start",
  "message": {
    "id": "msg_01...",
    "type": "message",
    "role": "assistant",
    "content": [],
    "model": "claude-sonnet-4-20250514",
    "stop_reason": null,
    "usage": {"input_tokens": 25, "output_tokens": 1}
  }
}
```

#### content_block_delta (text)
```json
{
  "type": "content_block_delta",
  "index": 0,
  "delta": {"type": "text_delta", "text": "Hello"}
}
```

#### content_block_delta (tool input)
```json
{
  "type": "content_block_delta",
  "index": 1,
  "delta": {"type": "input_json_delta", "partial_json": "{\"location\":"}
}
```

#### message_delta
```json
{
  "type": "message_delta",
  "delta": {"stop_reason": "end_turn"},
  "usage": {"output_tokens": 15}
}
```

### Capabilities

Claude provides these capabilities:

| Capability | Type | Description |
|------------|------|-------------|
| `streaming` | `:sampling` | Real-time response streaming |
| `tool_use` | `:tool` | Function calling |
| `vision` | `:resource` | Image understanding |
| `system_prompts` | `:prompt` | System prompt support |
| `interrupt` | `:sampling` | Request cancellation |

### Implementation Notes

1. **Streaming**: Use `stream: true` in request body
2. **Tool Results**: Send as user message with `tool_result` content
3. **Cancellation**: Close HTTP connection to abort stream
4. **Rate Limits**: Respect `retry-after` header on 429

## OpenAI / Codex Integration

### API Overview

OpenAI uses the Chat Completions API with SSE streaming.

**Endpoint**: `POST https://api.openai.com/v1/chat/completions`

**Headers**:
```
Authorization: Bearer {OPENAI_API_KEY}
content-type: application/json
```

### Event Mapping

| OpenAI Event | Normalized Event | Notes |
|--------------|------------------|-------|
| First chunk | `run_started` | Extract model info |
| `delta.content` | `message_streamed` | Text chunks |
| `delta.function_call` | Tool events | Function calling |
| `[DONE]` | `run_completed` | Stream end |
| Usage response | `token_usage_updated` | If `stream_options.include_usage` |

### OpenAI Event Shape

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion.chunk",
  "created": 1234567890,
  "model": "gpt-4",
  "choices": [{
    "index": 0,
    "delta": {"content": "Hello"},
    "finish_reason": null
  }]
}
```

### Capabilities

| Capability | Type | Description |
|------------|------|-------------|
| `streaming` | `:sampling` | Response streaming |
| `tool_use` | `:tool` | Function calling |
| `code_completion` | `:sampling` | Code-specific models |

## Error Handling

### Provider Errors

Errors from providers are normalized to `AgentSessionManager.Core.Error`:

```elixir
Error.new(:provider_rate_limited, "Rate limit exceeded",
  provider_error: %{
    status_code: 429,
    retry_after: 30
  }
)
```

### Error Categories

| Code | Description | Recovery |
|------|-------------|----------|
| `:provider_rate_limited` | Rate limit hit | Wait and retry |
| `:provider_timeout` | Request timeout | Retry with backoff |
| `:provider_error` | Generic API error | Check error details |
| `:provider_unavailable` | Service down | Retry later |
| `:invalid_api_key` | Auth failure | Check credentials |

## Configuration

### Environment Variables

| Provider | Variable | Format |
|----------|----------|--------|
| Claude | `ANTHROPIC_API_KEY` | `sk-ant-api03-...` |
| OpenAI | `OPENAI_API_KEY` | `sk-...` |

### Adapter Options

```elixir
# Claude Adapter
{:ok, adapter} = ClaudeAdapter.start_link(
  api_key: "sk-ant-...",
  model: "claude-sonnet-4-20250514",
  # For testing:
  sdk_module: MockSDK,
  sdk_pid: mock_pid
)

# Execute with options
ClaudeAdapter.execute(adapter, run, session,
  event_callback: &handle_event/1,
  timeout: 60_000
)
```

## Testing SDK Integration

### Mock SDK Usage

```elixir
# Start mock with scenario
{:ok, mock} = MockSDK.start_link(scenario: :successful_stream)

# Configure adapter to use mock
{:ok, adapter} = ClaudeAdapter.start_link(
  api_key: "test-key",
  sdk_module: MockSDK,
  sdk_pid: mock
)

# Control event emission
MockSDK.emit_next(mock)  # Emit one event
MockSDK.complete(mock)   # Emit all remaining
```

### Scenario Testing

Available mock scenarios:
- `:successful_stream` - Normal completion
- `:tool_use_response` - Tool call with input
- `:rate_limit_error` - 429 error
- `:network_timeout` - Timeout simulation
- `:partial_disconnect` - Mid-stream disconnect

## Best Practices

1. **Always check capabilities** before session creation
2. **Handle streaming errors** with proper cleanup
3. **Track token usage** for cost management
4. **Implement backoff** for rate limits
5. **Log events** for debugging and audit
6. **Use mock mode** in CI/CD pipelines
