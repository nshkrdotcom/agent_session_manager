defmodule AgentSessionManager.SupertesterCase do
  @moduledoc """
  Shared test infrastructure using Supertester for robust OTP testing.

  This module provides a drop-in replacement for `ExUnit.Case` that integrates
  Supertester's isolation, deterministic synchronization, and assertions.

  ## Usage

      defmodule MyTest do
        use AgentSessionManager.SupertesterCase, async: true

        test "my test", ctx do
          # ctx.isolation_context contains supertester isolation info
          {:ok, store} = setup_test_store(ctx)
          # ...
        end
      end

  ## Features

  - Full process isolation via Supertester.ExUnitFoundation
  - Automatic cleanup of GenServers started with setup helpers
  - Deterministic async testing with cast_and_sync patterns
  - Built-in assertions for GenServer state and process lifecycle
  - Telemetry isolation for async-safe telemetry testing
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Supertester.ExUnitFoundation, isolation: :full_isolation

      import Supertester.OTPHelpers
      import Supertester.GenServerHelpers
      import Supertester.Assertions
      import AgentSessionManager.SupertesterCase.Helpers

      alias AgentSessionManager.Adapters.InMemorySessionStore
      alias AgentSessionManager.Core.{Capability, Error, Event, Run, Session}
      alias AgentSessionManager.Ports.SessionStore
      alias AgentSessionManager.Test.{Fixtures, MockProviderAdapter}
    end
  end

  setup tags do
    # Allow tests to opt out of telemetry isolation
    if Map.get(tags, :telemetry_isolation, false) do
      {:ok, _} = Supertester.TelemetryHelpers.setup_telemetry_isolation()
    end

    :ok
  end
end
