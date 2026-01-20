# AgentSessionManager Examples

This directory contains comprehensive examples demonstrating the AgentSessionManager library.

## Live Session Example

The `live_session.exs` script demonstrates end-to-end usage with real SDKs and mock mode for CI and local development without credentials.

### Features Demonstrated

1. **Provider selection from command line** - Choose between Claude and Codex providers
2. **Registry setup** - Initialize registry with provider manifests
3. **Config loading** - Load configuration from environment variables
4. **Capability check** - Verify provider capabilities before session creation
5. **Streaming execution** - Single session with streaming message response
6. **Signal handling** - Clean interrupt via Ctrl+C
7. **Event logging** - Human-readable event output to stdout
8. **Usage summary** - Token usage and execution statistics

## Quick Start

### Running with Mock Mode (No Credentials Needed)

```bash
# Force mock mode
mix run examples/live_session.exs --provider claude --mock

# Or simply run without credentials (auto-detects mock mode)
mix run examples/live_session.exs --provider claude
```

### Running with Real API Credentials

```bash
# With Claude API
ANTHROPIC_API_KEY=sk-ant-api03-... mix run examples/live_session.exs --provider claude

# With Codex/OpenAI API
OPENAI_API_KEY=sk-... mix run examples/live_session.exs --provider codex
```

## Obtaining API Credentials

### Anthropic (Claude)

1. Create an account at [console.anthropic.com](https://console.anthropic.com)
2. Navigate to **API Keys** in your account settings
3. Click **Create Key** and copy your new API key
4. Export the key: `export ANTHROPIC_API_KEY=sk-ant-api03-...`

**Note**: Anthropic API keys start with `sk-ant-api03-`

### OpenAI (Codex)

1. Create an account at [platform.openai.com](https://platform.openai.com)
2. Navigate to **API keys** in your account settings
3. Click **Create new secret key** and copy it immediately (it won't be shown again)
4. Export the key: `export OPENAI_API_KEY=sk-...`

**Note**: OpenAI API keys start with `sk-`

## Command Line Options

```
Usage: mix run examples/live_session.exs [options]

Options:
  --provider, -p <name>  Provider to use (claude or codex). Default: claude
  --mock, -m             Force mock mode (no credentials needed)
  --help, -h             Show this help message

Environment Variables:
  ANTHROPIC_API_KEY      API key for Claude (Anthropic)
  OPENAI_API_KEY         API key for Codex (OpenAI)
```

## Expected Output

### Successful Run (Mock Mode)

```
AgentSessionManager - Live Session Example
==================================================
Provider: claude
Mode:     mock (forced)
==================================================

Step 1: Mode Detection
----------------------------------------
  [INFO] Running in mock mode
  [WARN] Using mock adapter - no real API calls will be made

Step 2: Registry Setup
----------------------------------------
  [INFO] Registry initialized with 1 provider(s)

Step 3: Configuration
----------------------------------------
  [INFO] Configuration loaded for provider: claude

Step 4: Capability Check
----------------------------------------
  [INFO] Capability negotiation: full
  [INFO] Available capabilities: streaming, tool_use, vision, system_prompts, interrupt

Step 5: Session Creation
----------------------------------------
  [INFO] Session created: ses_abc123...
  [INFO] Run created: run_def456...
  [INFO] Sending message: "Hello! What can you tell me about Elixir?"

--- Response ---

Elixir is a dynamic, functional programming language designed for building
scalable and maintainable applications.

Key features include:
- Runs on the BEAM VM
- Excellent concurrency
- Fault-tolerant design
- Great tooling with Mix

Step 7: Usage Summary
--- Usage Summary ---

  Input tokens:  25
  Output tokens: 85
  Total tokens:  110
  Duration:      550ms
  Events:        4
  Stop reason:   end_turn

Example completed successfully!
```

### Mock Mode Auto-Detection

When no credentials are found, the example automatically falls back to mock mode:

```
AgentSessionManager - Live Session Example
==================================================
Provider: claude
Mode:     auto-detect
==================================================

Step 1: Mode Detection
----------------------------------------
  [WARN] No ANTHROPIC_API_KEY found, running in mock mode...
  [INFO] Running in mock mode
  [WARN] Using mock adapter - no real API calls will be made

...
```

### Successful Run (Live Mode)

When running with real credentials, you'll see actual API responses:

```
Step 1: Mode Detection
----------------------------------------
  [INFO] Running in live mode

...

--- Response ---

[Actual response from the AI provider streamed in real-time]

Step 7: Usage Summary
--- Usage Summary ---

  Input tokens:  25
  Output tokens: 142
  Total tokens:  167
  Duration:      1250ms
  Events:        6
  Stop reason:   end_turn
```

## Troubleshooting

### Missing Credentials

**Error**: No API key found, running in mock mode

**Solution**:
- Set the appropriate environment variable
- Or use `--mock` flag if you want mock mode explicitly

```bash
# Set credentials
export ANTHROPIC_API_KEY=sk-ant-api03-...

# Or force mock mode
mix run examples/live_session.exs --provider claude --mock
```

### SDK Not Available

**Error**: SDK not available for claude

**Solution**: The live SDK integration requires additional dependencies. For now, use mock mode:

```bash
mix run examples/live_session.exs --provider claude --mock
```

To enable live mode, add the appropriate SDK to your `mix.exs`:

```elixir
# For Claude
{:anthropic, "~> 0.3"}

# For Codex
{:openai, "~> 0.5"}
```

Then run `mix deps.get`.

### Rate Limiting

**Error**: Rate limit exceeded (HTTP 429)

**Symptoms**:
- Error message mentions "rate_limit_error"
- Response includes "retry-after" header

**Solutions**:
1. Wait for the specified retry-after period
2. Check your API usage dashboard
3. Consider upgrading your API tier
4. Implement exponential backoff in production code

```bash
# Example error output
  [ERROR] Provider error: rate_limit_error
  [INFO] Retry after: 30 seconds
```

### Network Issues

**Error**: Request timed out / Connection refused

**Symptoms**:
- Timeout errors after 30+ seconds
- Connection refused messages

**Solutions**:
1. Check your internet connection
2. Verify the API endpoint is accessible
3. Check if you're behind a firewall or proxy
4. Try increasing timeout values

```bash
# Test connectivity
curl -I https://api.anthropic.com/v1/messages
```

### Invalid API Key

**Error**: Authentication failed / Invalid API key

**Symptoms**:
- HTTP 401 Unauthorized
- "invalid_api_key" error code

**Solutions**:
1. Verify the API key is correct (no extra spaces)
2. Check the key hasn't expired or been revoked
3. Ensure you're using the correct key for the provider
4. Regenerate the API key if needed

```bash
# Check your key format
echo $ANTHROPIC_API_KEY | head -c 20
# Should start with: sk-ant-api03-

echo $OPENAI_API_KEY | head -c 10
# Should start with: sk-
```

### Interrupt Handling

The example supports clean interruption via Ctrl+C:

1. Press `Ctrl+C` once to request graceful shutdown
2. The current operation will attempt to complete or cancel cleanly
3. Usage summary will be printed if possible
4. Press `Ctrl+C` again to force immediate exit

## CI/CD Integration

For CI pipelines, always use mock mode to avoid credential requirements and API costs:

```yaml
# GitHub Actions example
- name: Run example
  run: mix run examples/live_session.exs --provider claude --mock

# GitLab CI example
test_example:
  script:
    - mix run examples/live_session.exs --provider claude --mock
```

## Event Types Reference

The example demonstrates these event types:

| Event Type | Description |
|------------|-------------|
| `run_started` | Execution began |
| `message_streamed` | Streaming content chunk received |
| `message_received` | Complete message received |
| `token_usage_updated` | Token counts updated |
| `run_completed` | Execution finished successfully |
| `run_failed` | Execution failed with error |
| `run_cancelled` | Execution was cancelled |

## Contributing

To add new examples:

1. Create a new `.exs` file in this directory
2. Follow the pattern established in `live_session.exs`
3. Include comprehensive documentation and error handling
4. Support both mock and live modes where applicable
5. Update this README with your example
