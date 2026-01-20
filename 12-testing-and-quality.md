# Testing and Quality Guidelines

This document outlines the testing and quality standards for the AgentSessionManager library.

## Test Categories

### Unit Tests

Unit tests focus on individual modules and functions in isolation:

- **Core Domain Types**: Session, Run, Event, Capability, Manifest
- **Registry Operations**: Registration, lookup, filtering
- **Capability Resolution**: Negotiation logic, error handling
- **Error Types**: Error creation, formatting, categorization

Run unit tests:
```bash
mix test test/agent_session_manager/core/
```

### Integration Tests

Integration tests verify component interactions:

- **Session Lifecycle**: Create → Start → Execute → Complete
- **Provider Adapters**: Mock and real adapter contracts
- **Event Streaming**: Event emission and processing
- **Registry + Resolver**: End-to-end capability negotiation

Run integration tests:
```bash
mix test test/integration/
```

### Contract Tests

Contract tests verify behavior against defined interfaces:

- **SessionStore Contract**: All storage implementations
- **ProviderAdapter Contract**: All provider implementations

Run contract tests:
```bash
mix test test/agent_session_manager/ports/
```

### Load Tests

Load tests verify performance under stress (tagged with `:load_test`):

- **Streaming Throughput**: Events per second
- **Concurrent Sessions**: Multiple simultaneous sessions
- **Memory Usage**: Under sustained load

Run load tests:
```bash
mix test --only load_test
```

## Mock Infrastructure

### Claude Mock SDK

The `AgentSessionManager.Adapters.Claude.MockSDK` provides:

- Configurable scenarios (success, error, timeout)
- Event stream simulation
- Controllable timing
- Tool use simulation

Usage:
```elixir
{:ok, mock} = MockSDK.start_link(scenario: :successful_stream)
MockSDK.subscribe(mock, self())
MockSDK.emit_next(mock)
MockSDK.complete(mock)
```

### Mock Provider Adapter

The `AgentSessionManager.Test.MockProviderAdapter` provides:

- Configurable execution modes
- Response overrides
- Execution history tracking
- Cancellation simulation

Usage:
```elixir
{:ok, adapter} = MockProviderAdapter.start_link(
  execution_mode: :streaming,
  capabilities: Fixtures.provider_capabilities(:full_claude)
)
```

### Test Fixtures

The `AgentSessionManager.Test.Fixtures` module provides:

- Deterministic ID generation
- Golden event streams for scenarios
- Provider capability presets
- Error fixtures

Usage:
```elixir
import AgentSessionManager.Test.Fixtures

session = build_session(agent_id: "test")
events = golden_stream(:streaming_response)
caps = provider_capabilities(:full_claude)
```

## Quality Standards

### Code Coverage

Target: 90%+ line coverage for core modules

```bash
mix test --cover
```

### Static Analysis

Run Credo for code quality:
```bash
mix credo --strict
```

Run Dialyzer for type checking:
```bash
mix dialyxir
```

### Documentation

All public functions must have:
- `@doc` with description
- `@spec` with type specification
- Usage examples where appropriate

Generate docs:
```bash
mix docs
```

## CI/CD Integration

### Example Execution

CI should run examples in mock mode:
```bash
mix run examples/live_session.exs --provider claude --mock
```

### Test Matrix

- Elixir 1.14, 1.15, 1.16, 1.17, 1.18
- OTP 25, 26, 27
- All tests excluding load tests

### Quality Gates

Before merge:
1. All tests pass
2. No Credo issues
3. No Dialyzer warnings
4. Documentation generated
5. Example runs successfully

## Writing Tests

### Test Structure

```elixir
defmodule AgentSessionManager.Core.SessionTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.Session

  describe "Session.new/1" do
    test "creates session with valid attributes" do
      # Arrange
      attrs = %{agent_id: "test-agent"}

      # Act
      {:ok, session} = Session.new(attrs)

      # Assert
      assert session.agent_id == "test-agent"
      assert session.status == :pending
    end

    test "returns error for missing agent_id" do
      assert {:error, error} = Session.new(%{})
      assert error.code == :validation_error
    end
  end
end
```

### Async Testing

Most tests should be async:
```elixir
use ExUnit.Case, async: true
```

Exceptions:
- Tests using global state
- Tests with timing dependencies
- Load tests

### Fixtures vs Factories

Prefer fixtures for:
- Golden data that shouldn't change
- Scenario-based test data
- Shared test constants

Prefer factories for:
- Unique instances per test
- Customizable attributes
- Dynamic data needs
