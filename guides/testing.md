# Testing

AgentSessionManager is designed for testability. The ports and adapters architecture means you can test core logic in isolation, mock provider adapters, and use the in-memory store for fast tests.

## Testing Core Types

Core types are pure data structures -- no processes needed:

```elixir
defmodule MyApp.SessionTest do
  use ExUnit.Case

  alias AgentSessionManager.Core.{Session, Run, Event, Error}

  test "create and transition a session" do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    assert session.status == :pending
    assert session.agent_id == "test-agent"

    {:ok, active} = Session.update_status(session, :active)
    assert active.status == :active

    {:ok, completed} = Session.update_status(active, :completed)
    assert completed.status == :completed
  end

  test "session requires agent_id" do
    {:error, %Error{code: :validation_error}} = Session.new(%{})
  end

  test "run tracks token usage" do
    {:ok, run} = Run.new(%{session_id: "ses_123"})
    {:ok, run} = Run.update_token_usage(run, %{input_tokens: 100})
    {:ok, run} = Run.update_token_usage(run, %{input_tokens: 50, output_tokens: 75})

    assert run.token_usage == %{input_tokens: 150, output_tokens: 75}
  end

  test "events validate type" do
    {:ok, _} = Event.new(%{type: :message_received, session_id: "ses_1"})
    {:error, %Error{code: :invalid_event_type}} =
      Event.new(%{type: :not_a_type, session_id: "ses_1"})
  end
end
```

## Using the In-Memory Store

The `InMemorySessionStore` is purpose-built for testing -- ETS-backed for speed, GenServer-managed for consistency:

```elixir
defmodule MyApp.StoreTest do
  use ExUnit.Case

  alias AgentSessionManager.Core.{Session, Run, Event}
  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Ports.SessionStore

  setup do
    {:ok, store} = InMemorySessionStore.start_link()
    {:ok, store: store}
  end

  test "round-trip a session", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "test"})
    :ok = SessionStore.save_session(store, session)

    {:ok, retrieved} = SessionStore.get_session(store, session.id)
    assert retrieved.id == session.id
    assert retrieved.agent_id == "test"
  end

  test "append and query events", %{store: store} do
    {:ok, event1} = Event.new(%{type: :run_started, session_id: "ses_1", run_id: "run_1"})
    {:ok, event2} = Event.new(%{type: :message_received, session_id: "ses_1", run_id: "run_1"})

    :ok = SessionStore.append_event(store, event1)
    :ok = SessionStore.append_event(store, event2)

    {:ok, events} = SessionStore.get_events(store, "ses_1")
    assert length(events) == 2

    {:ok, filtered} = SessionStore.get_events(store, "ses_1", type: :run_started)
    assert length(filtered) == 1
  end

  test "event deduplication", %{store: store} do
    {:ok, event} = Event.new(%{type: :run_started, session_id: "ses_1"})

    :ok = SessionStore.append_event(store, event)
    :ok = SessionStore.append_event(store, event)  # same ID

    {:ok, events} = SessionStore.get_events(store, "ses_1")
    assert length(events) == 1
  end
end
```

## Mock Adapters for Provider Testing

All three built-in adapters accept `:sdk_module` and `:sdk_pid` options for injecting mock SDKs:

### Testing ClaudeAdapter

```elixir
defmodule MyApp.ClaudeAdapterTest do
  use ExUnit.Case

  alias AgentSessionManager.Adapters.ClaudeAdapter
  alias AgentSessionManager.Core.{Session, Run}

  defmodule MockSDK do
    use GenServer

    def start_link(events), do: GenServer.start_link(__MODULE__, events)
    def init(events), do: {:ok, %{events: events, subscribers: []}}

    def subscribe(pid, subscriber) do
      GenServer.call(pid, {:subscribe, subscriber})
    end

    def create_message(pid, _params) do
      GenServer.call(pid, :create_message)
    end

    def handle_call({:subscribe, subscriber}, _from, state) do
      {:reply, :ok, %{state | subscribers: [subscriber | state.subscribers]}}
    end

    def handle_call(:create_message, _from, state) do
      ref = make_ref()
      # Send events to subscribers
      for subscriber <- state.subscribers, event <- state.events do
        send(subscriber, {:claude_event, event})
      end
      {:reply, {:ok, ref}, state}
    end
  end

  test "adapter processes mock events" do
    events = [
      %{type: "message_start", message: %{id: "msg_1", model: "test", usage: %{}}},
      %{type: "content_block_start", index: 0, content_block: %{type: "text"}},
      %{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "Hello!"}},
      %{type: "content_block_stop", index: 0},
      %{type: "message_delta", delta: %{stop_reason: "end_turn"}, usage: %{output_tokens: 10}},
      %{type: "message_stop"}
    ]

    {:ok, mock} = MockSDK.start_link(events)

    {:ok, adapter} = ClaudeAdapter.start_link(
      api_key: "test-key",
      sdk_module: MockSDK,
      sdk_pid: mock
    )

    {:ok, session} = Session.new(%{agent_id: "test"})
    {:ok, run} = Run.new(%{session_id: session.id})

    collected_events = []
    callback = fn event ->
      send(self(), {:event, event})
    end

    {:ok, result} = ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
    assert result.output.content =~ "Hello"
  end
end
```

### Testing with SessionManager

```elixir
defmodule MyApp.IntegrationTest do
  use ExUnit.Case

  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Adapters.InMemorySessionStore

  setup do
    {:ok, store} = InMemorySessionStore.start_link()
    # Use a mock adapter or the real one with mock SDK
    {:ok, adapter} = start_mock_adapter()
    {:ok, store: store, adapter: adapter}
  end

  test "full session lifecycle", %{store: store, adapter: adapter} do
    # Create session
    {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test"})
    assert session.status == :pending

    # Activate
    {:ok, session} = SessionManager.activate_session(store, session.id)
    assert session.status == :active

    # Create and execute run
    {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{
      messages: [%{role: "user", content: "test"}]
    })
    {:ok, result} = SessionManager.execute_run(store, adapter, run.id)
    assert result.output != nil

    # Check events were stored
    {:ok, events} = SessionManager.get_session_events(store, session.id)
    event_types = Enum.map(events, & &1.type)
    assert :session_created in event_types
    assert :session_started in event_types

    # Complete
    {:ok, session} = SessionManager.complete_session(store, session.id)
    assert session.status == :completed
  end
end
```

## Testing Capability Negotiation

```elixir
defmodule MyApp.CapabilityTest do
  use ExUnit.Case

  alias AgentSessionManager.Core.{Capability, CapabilityResolver}

  test "full negotiation succeeds" do
    {:ok, resolver} = CapabilityResolver.new(required: [:sampling], optional: [:tool])

    capabilities = [
      %Capability{name: "streaming", type: :sampling, enabled: true},
      %Capability{name: "tool_use", type: :tool, enabled: true}
    ]

    {:ok, result} = CapabilityResolver.negotiate(resolver, capabilities)
    assert result.status == :full
  end

  test "missing required capability fails" do
    {:ok, resolver} = CapabilityResolver.new(required: [:tool])

    capabilities = [
      %Capability{name: "streaming", type: :sampling, enabled: true}
    ]

    {:error, error} = CapabilityResolver.negotiate(resolver, capabilities)
    assert error.code == :missing_required_capability
  end

  test "missing optional capability degrades" do
    {:ok, resolver} = CapabilityResolver.new(required: [:sampling], optional: [:tool])

    capabilities = [
      %Capability{name: "streaming", type: :sampling, enabled: true}
    ]

    {:ok, result} = CapabilityResolver.negotiate(resolver, capabilities)
    assert result.status == :degraded
    assert length(result.warnings) == 1
  end
end
```

## Testing Telemetry

```elixir
defmodule MyApp.TelemetryTest do
  use ExUnit.Case

  alias AgentSessionManager.Telemetry
  alias AgentSessionManager.Core.{Session, Run}

  test "emits run start event" do
    ref = :telemetry_test.attach_event_handlers(self(), [
      [:agent_session_manager, :run, :start]
    ])

    {:ok, session} = Session.new(%{agent_id: "test"})
    {:ok, run} = Run.new(%{session_id: session.id})

    Telemetry.emit_run_start(run, session)

    assert_received {[:agent_session_manager, :run, :start], ^ref, measurements, metadata}
    assert is_integer(measurements.system_time)
    assert metadata.run_id == run.id
    assert metadata.session_id == session.id
  end
end
```

## Testing Concurrency

```elixir
defmodule MyApp.ConcurrencyTest do
  use ExUnit.Case

  alias AgentSessionManager.Concurrency.ConcurrencyLimiter

  test "enforces session limits" do
    {:ok, limiter} = ConcurrencyLimiter.start_link(max_parallel_sessions: 2)

    :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "ses_1")
    :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "ses_2")

    {:error, error} = ConcurrencyLimiter.acquire_session_slot(limiter, "ses_3")
    assert error.code == :max_sessions_exceeded
  end

  test "idempotent acquire" do
    {:ok, limiter} = ConcurrencyLimiter.start_link(max_parallel_sessions: 1)

    :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "ses_1")
    :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "ses_1")  # same ID, no error

    status = ConcurrencyLimiter.get_status(limiter)
    assert status.active_sessions == 1
  end
end
```

## Process Cleanup with `cleanup_on_exit`

The project uses `Supertester.OTPHelpers.cleanup_on_exit/1` for process teardown instead of manual `on_exit` blocks. This helper safely stops a process when the test exits, handling the case where the process may already be dead:

```elixir
use AgentSessionManager.SupertesterCase, async: true

setup do
  {:ok, store} = InMemorySessionStore.start_link([])
  cleanup_on_exit(fn -> safe_stop(store) end)

  {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
  cleanup_on_exit(fn -> safe_stop(adapter) end)

  {:ok, store: store, adapter: adapter}
end
```

The `safe_stop/1` helper attempts `GenServer.stop/1` and silently catches exits if the process is already down.

## Concurrent Telemetry Tests

Because `Telemetry.set_enabled/1` and `AuditLogger.set_enabled/1` now use process-local overrides via `AgentSessionManager.Config`, telemetry tests can run with `async: true`. Each test process has its own override that doesn't interfere with other tests.

When asserting that events are **not** emitted, filter by `session_id` to avoid false positives from events emitted by concurrent tests:

```elixir
# Good -- scoped to this test's session
refute_event(ref, session.id)

# Fragile -- may catch events from other concurrent tests
refute_event(ref)
```

## Tips

- Use `InMemorySessionStore` for all tests -- it's fast and isolated per process
- Inject mock SDKs via `:sdk_module` / `:sdk_pid` to test adapter behavior without real API calls
- Test core types directly -- they're pure functions, no setup needed
- Use `ExUnit.CaptureLog` to verify logging output
- The telemetry test helpers from `:telemetry_test` make it straightforward to assert on emitted events
- Use `cleanup_on_exit` for process teardown instead of manual `on_exit` blocks
- Telemetry and audit logging tests can run concurrently thanks to process-local config overrides
