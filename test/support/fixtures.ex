defmodule AgentSessionManager.Test.Fixtures do
  @moduledoc """
  Comprehensive test fixture suite for AgentSessionManager.

  Provides:
  - Golden event stream fixtures for common scenarios
  - Provider capability fixtures for negotiation testing
  - Session, Run, and Event factory helpers
  - Deterministic and parallel-safe data generation

  ## Usage

      import AgentSessionManager.Test.Fixtures

      # Generate fixtures
      events = golden_stream(:simple_message)
      caps = provider_capabilities(:full_claude)

      # Build domain objects
      session = build_session(agent_id: "my-agent")
      run = build_run(session_id: session.id)

  ## Design Principles

  - All fixtures are deterministic (no random generation in default values)
  - Thread-safe for parallel test execution
  - Composable for building complex scenarios
  """

  alias AgentSessionManager.Core.{Capability, Error, Event, Run, Session}

  # ============================================================================
  # Session Fixtures
  # ============================================================================

  @doc """
  Builds a session struct with optional overrides.

  ## Options

  - `:id` - Custom session ID (default: deterministic based on index)
  - `:agent_id` - Agent identifier (default: "test-agent")
  - `:status` - Session status (default: :pending)
  - `:metadata` - Metadata map (default: %{})
  - `:context` - Context map (default: %{})
  - `:tags` - Tag list (default: [])
  - `:index` - Index for deterministic ID generation (default: 1)

  ## Examples

      session = build_session()
      session = build_session(agent_id: "claude-agent", status: :active)
      session = build_session(index: 5)  # ses_test_000005

  """
  @spec build_session(keyword()) :: Session.t()
  def build_session(opts \\ []) do
    index = Keyword.get(opts, :index, 1)
    id = Keyword.get(opts, :id, session_id(index))
    now = DateTime.utc_now()

    %Session{
      id: id,
      agent_id: Keyword.get(opts, :agent_id, "test-agent"),
      status: Keyword.get(opts, :status, :pending),
      parent_session_id: Keyword.get(opts, :parent_session_id),
      metadata: Keyword.get(opts, :metadata, %{}),
      context: Keyword.get(opts, :context, %{}),
      tags: Keyword.get(opts, :tags, []),
      created_at: Keyword.get(opts, :created_at, now),
      updated_at: Keyword.get(opts, :updated_at, now)
    }
  end

  @doc """
  Generates a deterministic session ID.
  """
  @spec session_id(non_neg_integer()) :: String.t()
  def session_id(index) when is_integer(index) and index >= 0 do
    "ses_test_#{String.pad_leading(Integer.to_string(index), 6, "0")}"
  end

  # ============================================================================
  # Run Fixtures
  # ============================================================================

  @doc """
  Builds a run struct with optional overrides.

  ## Options

  - `:id` - Custom run ID (default: deterministic based on index)
  - `:session_id` - Parent session ID (required or default: ses_test_000001)
  - `:status` - Run status (default: :pending)
  - `:input` - Input map (default: %{prompt: "Test prompt"})
  - `:output` - Output map (default: nil)
  - `:error` - Error map (default: nil)
  - `:metadata` - Metadata map (default: %{})
  - `:turn_count` - Turn count (default: 0)
  - `:token_usage` - Token usage map (default: %{})
  - `:index` - Index for deterministic ID generation (default: 1)

  ## Examples

      run = build_run(session_id: "ses_test_000001")
      run = build_run(status: :running, input: %{messages: []})

  """
  @spec build_run(keyword()) :: Run.t()
  def build_run(opts \\ []) do
    index = Keyword.get(opts, :index, 1)
    id = Keyword.get(opts, :id, run_id(index))
    now = DateTime.utc_now()

    %Run{
      id: id,
      session_id: Keyword.get(opts, :session_id, session_id(1)),
      status: Keyword.get(opts, :status, :pending),
      input: Keyword.get(opts, :input, %{prompt: "Test prompt"}),
      output: Keyword.get(opts, :output),
      error: Keyword.get(opts, :error),
      metadata: Keyword.get(opts, :metadata, %{}),
      turn_count: Keyword.get(opts, :turn_count, 0),
      token_usage: Keyword.get(opts, :token_usage, %{}),
      started_at: Keyword.get(opts, :started_at, now),
      ended_at: Keyword.get(opts, :ended_at)
    }
  end

  @doc """
  Generates a deterministic run ID.
  """
  @spec run_id(non_neg_integer()) :: String.t()
  def run_id(index) when is_integer(index) and index >= 0 do
    "run_test_#{String.pad_leading(Integer.to_string(index), 6, "0")}"
  end

  # ============================================================================
  # Event Fixtures
  # ============================================================================

  @doc """
  Builds an event struct with optional overrides.

  ## Options

  - `:id` - Custom event ID (default: deterministic based on index)
  - `:type` - Event type (required or default: :message_received)
  - `:session_id` - Session ID (required or default: ses_test_000001)
  - `:run_id` - Run ID (optional)
  - `:data` - Event data map (default: %{})
  - `:metadata` - Metadata map (default: %{})
  - `:sequence_number` - Sequence number (optional)
  - `:index` - Index for deterministic ID generation (default: 1)

  """
  @spec build_event(keyword()) :: Event.t()
  def build_event(opts \\ []) do
    index = Keyword.get(opts, :index, 1)
    id = Keyword.get(opts, :id, event_id(index))

    %Event{
      id: id,
      type: Keyword.get(opts, :type, :message_received),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      session_id: Keyword.get(opts, :session_id, session_id(1)),
      run_id: Keyword.get(opts, :run_id),
      data: Keyword.get(opts, :data, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      sequence_number: Keyword.get(opts, :sequence_number)
    }
  end

  @doc """
  Generates a deterministic event ID.
  """
  @spec event_id(non_neg_integer()) :: String.t()
  def event_id(index) when is_integer(index) and index >= 0 do
    "evt_test_#{String.pad_leading(Integer.to_string(index), 6, "0")}"
  end

  # ============================================================================
  # Capability Fixtures
  # ============================================================================

  @doc """
  Builds a capability struct with optional overrides.
  """
  @spec build_capability(keyword()) :: Capability.t()
  def build_capability(opts \\ []) do
    %Capability{
      name: Keyword.get(opts, :name, "test_capability"),
      type: Keyword.get(opts, :type, :tool),
      enabled: Keyword.get(opts, :enabled, true),
      description: Keyword.get(opts, :description),
      config: Keyword.get(opts, :config, %{}),
      permissions: Keyword.get(opts, :permissions, [])
    }
  end

  @doc """
  Returns a predefined set of provider capabilities.

  ## Available Sets

  - `:full_claude` - All Claude provider capabilities
  - `:minimal` - Basic chat only
  - `:with_tools` - Chat with tool support
  - `:streaming_only` - Streaming without tools
  - `:no_interrupt` - Capabilities without interrupt support

  """
  @spec provider_capabilities(atom()) :: [Capability.t()]
  def provider_capabilities(:full_claude) do
    [
      %Capability{
        name: "streaming",
        type: :sampling,
        enabled: true,
        description: "Real-time streaming of responses"
      },
      %Capability{
        name: "tool_use",
        type: :tool,
        enabled: true,
        description: "Tool/function calling capability"
      },
      %Capability{
        name: "vision",
        type: :resource,
        enabled: true,
        description: "Image understanding capability"
      },
      %Capability{
        name: "system_prompts",
        type: :prompt,
        enabled: true,
        description: "System prompt support"
      },
      %Capability{
        name: "interrupt",
        type: :sampling,
        enabled: true,
        description: "Ability to interrupt/cancel in-progress requests"
      }
    ]
  end

  def provider_capabilities(:minimal) do
    [
      %Capability{
        name: "chat",
        type: :tool,
        enabled: true,
        description: "Basic chat capability"
      }
    ]
  end

  def provider_capabilities(:with_tools) do
    [
      %Capability{
        name: "chat",
        type: :tool,
        enabled: true,
        description: "Basic chat capability"
      },
      %Capability{
        name: "tool_use",
        type: :tool,
        enabled: true,
        description: "Tool/function calling capability"
      },
      %Capability{
        name: "sampling",
        type: :sampling,
        enabled: true,
        description: "Text sampling capability"
      }
    ]
  end

  def provider_capabilities(:streaming_only) do
    [
      %Capability{
        name: "streaming",
        type: :sampling,
        enabled: true,
        description: "Real-time streaming of responses"
      },
      %Capability{
        name: "chat",
        type: :tool,
        enabled: true,
        description: "Basic chat capability"
      }
    ]
  end

  def provider_capabilities(:no_interrupt) do
    [
      %Capability{
        name: "streaming",
        type: :sampling,
        enabled: true,
        description: "Real-time streaming of responses"
      },
      %Capability{
        name: "tool_use",
        type: :tool,
        enabled: true,
        description: "Tool/function calling capability"
      },
      %Capability{
        name: "chat",
        type: :tool,
        enabled: true,
        description: "Basic chat capability"
      }
    ]
  end

  # ============================================================================
  # Golden Event Stream Fixtures
  # ============================================================================

  @doc """
  Returns a golden event stream for testing.

  Golden streams are predefined sequences of events that represent
  common scenarios. They are deterministic and can be used to verify
  event processing logic.

  ## Available Streams

  - `:simple_message` - Basic user message and assistant response
  - `:streaming_response` - Streamed response with multiple chunks
  - `:tool_use` - Tool call and response
  - `:multi_turn` - Multi-turn conversation
  - `:error_recovery` - Error followed by recovery
  - `:cancelled_run` - Run that was cancelled mid-execution
  - `:rate_limited` - Rate limit error scenario
  - `:session_lifecycle` - Complete session from creation to completion

  ## Options

  - `:session_id` - Override session ID (default: ses_test_000001)
  - `:run_id` - Override run ID (default: run_test_000001)

  """
  @spec golden_stream(atom(), keyword()) :: [Event.t()]
  def golden_stream(scenario, opts \\ [])

  def golden_stream(:simple_message, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      %Event{
        id: "evt_golden_001",
        type: :run_started,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_golden_002",
        type: :message_received,
        timestamp: DateTime.add(base_time, 100, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "Hello! How can I help you today?", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_golden_003",
        type: :token_usage_updated,
        timestamp: DateTime.add(base_time, 150, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{input_tokens: 10, output_tokens: 15},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_golden_004",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 200, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{stop_reason: "end_turn"},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:streaming_response, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      %Event{
        id: "evt_stream_001",
        type: :run_started,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_stream_002",
        type: :message_streamed,
        timestamp: DateTime.add(base_time, 50, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "Hello", delta: "Hello", index: 0},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_stream_003",
        type: :message_streamed,
        timestamp: DateTime.add(base_time, 100, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "! How ", delta: "! How ", index: 0},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_stream_004",
        type: :message_streamed,
        timestamp: DateTime.add(base_time, 150, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "can I help?", delta: "can I help?", index: 0},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_stream_005",
        type: :message_received,
        timestamp: DateTime.add(base_time, 200, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "Hello! How can I help?", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_stream_006",
        type: :token_usage_updated,
        timestamp: DateTime.add(base_time, 210, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{input_tokens: 10, output_tokens: 12},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_stream_007",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 250, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{stop_reason: "end_turn"},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:tool_use, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      %Event{
        id: "evt_tool_001",
        type: :run_started,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_tool_002",
        type: :message_streamed,
        timestamp: DateTime.add(base_time, 50, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{
          content: "Let me check the weather for you.",
          delta: "Let me check the weather for you.",
          index: 0
        },
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_tool_003",
        type: :tool_call_started,
        timestamp: DateTime.add(base_time, 100, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{tool_use_id: "toolu_test_001", tool_name: "get_weather", index: 1},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_tool_004",
        type: :tool_call_completed,
        timestamp: DateTime.add(base_time, 150, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{
          tool_use_id: "toolu_test_001",
          tool_name: "get_weather",
          input: %{"location" => "San Francisco"},
          index: 1
        },
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_tool_005",
        type: :message_received,
        timestamp: DateTime.add(base_time, 200, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "Let me check the weather for you.", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_tool_006",
        type: :token_usage_updated,
        timestamp: DateTime.add(base_time, 210, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{input_tokens: 25, output_tokens: 45},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_tool_007",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 250, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{stop_reason: "tool_use"},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:multi_turn, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id_1 = Keyword.get(opts, :run_id_1, run_id(1))
    run_id_2 = Keyword.get(opts, :run_id_2, run_id(2))
    base_time = DateTime.utc_now()

    # First turn
    [
      %Event{
        id: "evt_multi_001",
        type: :run_started,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id_1,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_multi_002",
        type: :message_received,
        timestamp: DateTime.add(base_time, 100, :millisecond),
        session_id: session_id,
        run_id: run_id_1,
        data: %{content: "Hello! I'm here to help.", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_multi_003",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 150, :millisecond),
        session_id: session_id,
        run_id: run_id_1,
        data: %{stop_reason: "end_turn"},
        metadata: %{provider: :claude}
      },
      # Second turn
      %Event{
        id: "evt_multi_004",
        type: :run_started,
        timestamp: DateTime.add(base_time, 500, :millisecond),
        session_id: session_id,
        run_id: run_id_2,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_multi_005",
        type: :message_received,
        timestamp: DateTime.add(base_time, 600, :millisecond),
        session_id: session_id,
        run_id: run_id_2,
        data: %{content: "Sure, I can help with that!", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_multi_006",
        type: :turn_completed,
        timestamp: DateTime.add(base_time, 620, :millisecond),
        session_id: session_id,
        run_id: run_id_2,
        data: %{turn_number: 2},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_multi_007",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 650, :millisecond),
        session_id: session_id,
        run_id: run_id_2,
        data: %{stop_reason: "end_turn"},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:error_recovery, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      %Event{
        id: "evt_err_001",
        type: :run_started,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_err_002",
        type: :error_occurred,
        timestamp: DateTime.add(base_time, 100, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{error_code: :provider_error, error_message: "Temporary error"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_err_003",
        type: :error_recovered,
        timestamp: DateTime.add(base_time, 200, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{recovery_action: "retry"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_err_004",
        type: :message_received,
        timestamp: DateTime.add(base_time, 350, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "Successfully recovered!", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_err_005",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 400, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{stop_reason: "end_turn"},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:cancelled_run, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      %Event{
        id: "evt_cancel_001",
        type: :run_started,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_cancel_002",
        type: :message_streamed,
        timestamp: DateTime.add(base_time, 50, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "I'm starting to...", delta: "I'm starting to...", index: 0},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_cancel_003",
        type: :run_cancelled,
        timestamp: DateTime.add(base_time, 100, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{reason: "user_requested"},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:rate_limited, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      %Event{
        id: "evt_rate_001",
        type: :error_occurred,
        timestamp: base_time,
        session_id: session_id,
        run_id: run_id,
        data: %{
          error_code: :provider_rate_limited,
          error_message: "Rate limit exceeded",
          retry_after: 30
        },
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_rate_002",
        type: :run_failed,
        timestamp: DateTime.add(base_time, 10, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{error_code: :provider_rate_limited},
        metadata: %{provider: :claude}
      }
    ]
  end

  def golden_stream(:session_lifecycle, opts) do
    session_id = Keyword.get(opts, :session_id, session_id(1))
    run_id = Keyword.get(opts, :run_id, run_id(1))
    base_time = DateTime.utc_now()

    [
      # Session events
      %Event{
        id: "evt_lifecycle_001",
        type: :session_created,
        timestamp: base_time,
        session_id: session_id,
        run_id: nil,
        data: %{agent_id: "test-agent"},
        metadata: %{}
      },
      %Event{
        id: "evt_lifecycle_002",
        type: :session_started,
        timestamp: DateTime.add(base_time, 10, :millisecond),
        session_id: session_id,
        run_id: nil,
        data: %{},
        metadata: %{}
      },
      # Run events
      %Event{
        id: "evt_lifecycle_003",
        type: :run_started,
        timestamp: DateTime.add(base_time, 50, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{model: "claude-sonnet-4-20250514"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_lifecycle_004",
        type: :message_received,
        timestamp: DateTime.add(base_time, 150, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{content: "Hello!", role: "assistant"},
        metadata: %{provider: :claude}
      },
      %Event{
        id: "evt_lifecycle_005",
        type: :run_completed,
        timestamp: DateTime.add(base_time, 200, :millisecond),
        session_id: session_id,
        run_id: run_id,
        data: %{stop_reason: "end_turn"},
        metadata: %{provider: :claude}
      },
      # Session completion
      %Event{
        id: "evt_lifecycle_006",
        type: :session_completed,
        timestamp: DateTime.add(base_time, 300, :millisecond),
        session_id: session_id,
        run_id: nil,
        data: %{},
        metadata: %{}
      }
    ]
  end

  # ============================================================================
  # Error Fixtures
  # ============================================================================

  @doc """
  Returns a predefined error for testing.

  ## Available Errors

  - `:validation_error` - Validation failed
  - `:session_not_found` - Session not found
  - `:run_not_found` - Run not found
  - `:provider_error` - Generic provider error
  - `:provider_timeout` - Provider timeout
  - `:provider_rate_limited` - Rate limited
  - `:cancelled` - Operation cancelled
  - `:missing_required_capability` - Missing capability

  """
  @spec error(atom()) :: Error.t()
  def error(:validation_error) do
    Error.new(:validation_error, "Validation failed: field is required")
  end

  def error(:session_not_found) do
    Error.new(:session_not_found, "Session not found: ses_test_000001")
  end

  def error(:run_not_found) do
    Error.new(:run_not_found, "Run not found: run_test_000001")
  end

  def error(:provider_error) do
    Error.new(:provider_error, "Provider returned an error")
  end

  def error(:provider_timeout) do
    Error.new(:provider_timeout, "Request timed out")
  end

  def error(:provider_rate_limited) do
    Error.new(:provider_rate_limited, "Rate limit exceeded",
      provider_error: %{
        status_code: 429,
        retry_after: 30
      }
    )
  end

  def error(:cancelled) do
    Error.new(:cancelled, "Operation was cancelled")
  end

  def error(:missing_required_capability) do
    Error.new(:missing_required_capability, "Required capability not available: file_access")
  end

  # ============================================================================
  # Execution Result Fixtures
  # ============================================================================

  @doc """
  Returns a predefined execution result for testing.

  ## Available Results

  - `:successful` - Successful execution with output
  - `:tool_use` - Execution that resulted in tool use
  - `:empty_response` - Valid but empty response

  """
  @spec execution_result(atom()) :: map()
  def execution_result(:successful) do
    %{
      output: %{
        content: "Hello! How can I help you today?",
        stop_reason: "end_turn",
        tool_calls: []
      },
      token_usage: %{
        input_tokens: 10,
        output_tokens: 15
      },
      events: []
    }
  end

  def execution_result(:tool_use) do
    %{
      output: %{
        content: "Let me check the weather for you.",
        stop_reason: "tool_use",
        tool_calls: [
          %{
            id: "toolu_test_001",
            name: "get_weather",
            input: %{"location" => "San Francisco"}
          }
        ]
      },
      token_usage: %{
        input_tokens: 25,
        output_tokens: 45
      },
      events: []
    }
  end

  def execution_result(:empty_response) do
    %{
      output: %{
        content: "",
        stop_reason: "end_turn",
        tool_calls: []
      },
      token_usage: %{
        input_tokens: 5,
        output_tokens: 0
      },
      events: []
    }
  end
end
