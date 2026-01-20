# ADR 0008: Live Examples Architecture

## Status

Accepted

## Context

We need comprehensive examples that demonstrate end-to-end usage of the AgentSessionManager library. These examples must:

1. Work in CI environments without API credentials
2. Support real SDK integration when credentials are available
3. Demonstrate all major library features in a single, coherent script
4. Provide clear error messages for common issues
5. Be maintainable and serve as documentation

## Decision

We will implement a single comprehensive example script (`examples/live_session.exs`) with the following architecture:

### Dual-Mode Operation

The example supports two modes of operation:

1. **Live Mode**: Uses real SDK adapters when API credentials are available
2. **Mock Mode**: Uses mock adapters for CI and local development without credentials

Mode selection follows this priority:
- Explicit `--mock` flag forces mock mode
- Environment variable presence determines live vs mock mode
- Missing credentials auto-fall back to mock mode with a warning

### Provider Abstraction

The example abstracts provider differences through:
- Command-line `--provider` flag (claude, codex)
- Provider-specific manifests defining capabilities
- Provider-specific environment variables

### Feature Demonstration

The script demonstrates these features in sequence:
1. Registry setup with provider manifests
2. Configuration loading from environment
3. Capability negotiation before session creation
4. Session and run lifecycle management
5. Streaming response handling with event callbacks
6. Clean signal handling (Ctrl+C)
7. Human-readable event logging
8. Usage summary (tokens, duration, events)

### Error Handling

The example provides graceful degradation:
- Missing SDK → Clear installation instructions + mock fallback
- Missing credentials → Auto-switch to mock mode with warning
- Invalid provider → Usage help and exit
- Runtime errors → Formatted error messages

## Consequences

### Positive

- Single script serves as complete reference for library usage
- CI can run examples without credentials or external dependencies
- Developers can test locally without API setup
- Example output serves as documentation

### Negative

- Single file becomes quite long (~600 lines)
- Mock mode doesn't validate real API behavior
- Some complexity in dual-mode logic

### Mitigations

- Well-organized sections with clear comments
- Comprehensive README documents all usage patterns
- Integration tests with mock adapters verify behavior

## Implementation Notes

### File Structure

```
examples/
├── live_session.exs    # Main example script
└── README.md           # Documentation for running examples
```

### Command Line Interface

```bash
# Basic usage
mix run examples/live_session.exs [options]

# Options
--provider, -p <name>  # Provider: claude, codex
--mock, -m             # Force mock mode
--help, -h             # Show help
```

### Environment Variables

- `ANTHROPIC_API_KEY` - Claude/Anthropic API key
- `OPENAI_API_KEY` - Codex/OpenAI API key

### Output Format

The example produces structured output with:
- Step headers with numbering
- Info/warning/error prefixes
- ANSI colors for terminal readability
- Event logs to stderr
- Streamed content to stdout

## References

- [AgentSessionManager Core API](../lib/agent_session_manager.ex)
- [Claude Adapter Implementation](../lib/agent_session_manager/adapters/claude_adapter.ex)
- [Mock Provider Adapter](../test/support/mock_provider_adapter.ex)
