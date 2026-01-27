# Examples

This directory contains runnable examples that demonstrate AgentSessionManager functionality end-to-end.

## Available Examples

### `live_session.exs` -- Live Session with Streaming

Demonstrates the full session lifecycle with a real AI provider:

- Provider selection (Claude or Codex) via command line
- Registry initialization with provider manifests
- Configuration and capability negotiation
- Adapter startup and streaming execution
- Event logging to stderr in human-readable format
- Token usage and execution statistics
- Clean interrupt via Ctrl+C

## Running Examples

### Prerequisites

Each SDK handles authentication via its own login mechanism:

- **Claude**: Run `claude login` (or set `ANTHROPIC_API_KEY`)
- **Codex**: Run `codex login` (or set `CODEX_API_KEY`)

### Single Example

```bash
mix run examples/live_session.exs --provider claude
mix run examples/live_session.exs --provider codex
```

### Run All Examples

```bash
./examples/run_all.sh
```

## Command Line Options

```
Usage: mix run examples/live_session.exs [options]

Options:
  --provider, -p <name>  Provider to use (claude or codex). Default: claude
  --help, -h             Show this help message

Authentication:
  Claude: Run `claude login` or set ANTHROPIC_API_KEY
  Codex:  Run `codex login` or set CODEX_API_KEY
```

## Obtaining Credentials

### Anthropic (Claude)

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code`
2. Run `claude login` to authenticate via browser
3. Alternatively, set `ANTHROPIC_API_KEY` from [console.anthropic.com](https://console.anthropic.com)

### OpenAI (Codex)

1. Install Codex CLI
2. Run `codex login` to authenticate
3. Alternatively, set `CODEX_API_KEY` from [platform.openai.com](https://platform.openai.com)

## Troubleshooting

### Authentication errors

Ensure you have run `claude login` or `codex login` for the provider you are using.
If using environment variables, verify they are set in your current shell.

### SDK not available

The live SDK integration requires the provider SDK dependencies. See the error output for installation instructions.

### Rate limiting

If you see rate limit errors (HTTP 429), wait for the retry-after period or check your API usage dashboard.

## Adding New Examples

1. Create a new `.exs` file in this directory
2. Include clear output formatting and error handling
3. Add the example to `run_all.sh`
4. Document it in this README
