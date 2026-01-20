defmodule AgentSessionManager.Test.FixturesTest do
  @moduledoc """
  Tests for the test fixtures module.

  Verifies that fixtures are:
  - Deterministic (same input produces same output)
  - Valid (conform to their struct specifications)
  - Reusable across test modules
  """

  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.{Capability, Event, Run, Session}
  alias AgentSessionManager.Test.Fixtures

  # ============================================================================
  # Session Fixture Tests
  # ============================================================================

  describe "build_session/1" do
    test "builds a valid session struct" do
      session = Fixtures.build_session()

      assert %Session{} = session
      assert session.id != nil
      assert session.agent_id == "test-agent"
      assert session.status == :pending
    end

    test "generates deterministic IDs based on index" do
      session1 = Fixtures.build_session(index: 1)
      session2 = Fixtures.build_session(index: 1)
      session3 = Fixtures.build_session(index: 2)

      assert session1.id == session2.id
      assert session1.id != session3.id
      assert session1.id == "ses_test_000001"
      assert session3.id == "ses_test_000002"
    end

    test "accepts all configuration options" do
      session =
        Fixtures.build_session(
          id: "custom-id",
          agent_id: "custom-agent",
          status: :active,
          parent_session_id: "parent-123",
          metadata: %{key: "value"},
          context: %{system_prompt: "Be helpful"},
          tags: ["test", "integration"]
        )

      assert session.id == "custom-id"
      assert session.agent_id == "custom-agent"
      assert session.status == :active
      assert session.parent_session_id == "parent-123"
      assert session.metadata == %{key: "value"}
      assert session.context == %{system_prompt: "Be helpful"}
      assert session.tags == ["test", "integration"]
    end
  end

  describe "session_id/1" do
    test "generates deterministic IDs" do
      assert Fixtures.session_id(0) == "ses_test_000000"
      assert Fixtures.session_id(1) == "ses_test_000001"
      assert Fixtures.session_id(999_999) == "ses_test_999999"
    end
  end

  # ============================================================================
  # Run Fixture Tests
  # ============================================================================

  describe "build_run/1" do
    test "builds a valid run struct" do
      run = Fixtures.build_run()

      assert %Run{} = run
      assert run.id != nil
      assert run.session_id == "ses_test_000001"
      assert run.status == :pending
    end

    test "generates deterministic IDs based on index" do
      run1 = Fixtures.build_run(index: 1)
      run2 = Fixtures.build_run(index: 1)
      run3 = Fixtures.build_run(index: 2)

      assert run1.id == run2.id
      assert run1.id != run3.id
      assert run1.id == "run_test_000001"
    end

    test "accepts all configuration options" do
      run =
        Fixtures.build_run(
          id: "custom-run",
          session_id: "ses_custom",
          status: :running,
          input: %{messages: []},
          output: %{content: "Response"},
          error: %{code: :test_error},
          metadata: %{attempt: 1},
          turn_count: 2,
          token_usage: %{input_tokens: 100, output_tokens: 50}
        )

      assert run.id == "custom-run"
      assert run.session_id == "ses_custom"
      assert run.status == :running
      assert run.input == %{messages: []}
      assert run.output == %{content: "Response"}
      assert run.error == %{code: :test_error}
      assert run.metadata == %{attempt: 1}
      assert run.turn_count == 2
      assert run.token_usage == %{input_tokens: 100, output_tokens: 50}
    end
  end

  # ============================================================================
  # Event Fixture Tests
  # ============================================================================

  describe "build_event/1" do
    test "builds a valid event struct" do
      event = Fixtures.build_event()

      assert %Event{} = event
      assert event.id != nil
      assert event.type == :message_received
      assert event.session_id == "ses_test_000001"
    end

    test "generates deterministic IDs based on index" do
      event1 = Fixtures.build_event(index: 1)
      event2 = Fixtures.build_event(index: 1)
      event3 = Fixtures.build_event(index: 2)

      assert event1.id == event2.id
      assert event1.id != event3.id
      assert event1.id == "evt_test_000001"
    end

    test "accepts all configuration options" do
      event =
        Fixtures.build_event(
          id: "custom-event",
          type: :run_started,
          session_id: "ses_custom",
          run_id: "run_custom",
          data: %{model: "test-model"},
          metadata: %{provider: :test},
          sequence_number: 5
        )

      assert event.id == "custom-event"
      assert event.type == :run_started
      assert event.session_id == "ses_custom"
      assert event.run_id == "run_custom"
      assert event.data == %{model: "test-model"}
      assert event.metadata == %{provider: :test}
      assert event.sequence_number == 5
    end
  end

  # ============================================================================
  # Capability Fixture Tests
  # ============================================================================

  describe "build_capability/1" do
    test "builds a valid capability struct" do
      capability = Fixtures.build_capability()

      assert %Capability{} = capability
      assert capability.name == "test_capability"
      assert capability.type == :tool
      assert capability.enabled == true
    end

    test "accepts all configuration options" do
      capability =
        Fixtures.build_capability(
          name: "custom_cap",
          type: :sampling,
          enabled: false,
          description: "A test capability",
          config: %{max_tokens: 1000},
          permissions: ["read", "write"]
        )

      assert capability.name == "custom_cap"
      assert capability.type == :sampling
      assert capability.enabled == false
      assert capability.description == "A test capability"
      assert capability.config == %{max_tokens: 1000}
      assert capability.permissions == ["read", "write"]
    end
  end

  describe "provider_capabilities/1" do
    test ":full_claude returns all Claude capabilities" do
      caps = Fixtures.provider_capabilities(:full_claude)

      assert is_list(caps)
      assert length(caps) == 5

      cap_names = Enum.map(caps, & &1.name)
      assert "streaming" in cap_names
      assert "tool_use" in cap_names
      assert "vision" in cap_names
      assert "system_prompts" in cap_names
      assert "interrupt" in cap_names
    end

    test ":minimal returns basic capabilities" do
      caps = Fixtures.provider_capabilities(:minimal)

      assert is_list(caps)
      assert length(caps) == 1

      cap_names = Enum.map(caps, & &1.name)
      assert "chat" in cap_names
    end

    test ":with_tools returns chat and tool capabilities" do
      caps = Fixtures.provider_capabilities(:with_tools)

      cap_names = Enum.map(caps, & &1.name)
      assert "chat" in cap_names
      assert "tool_use" in cap_names
      assert "sampling" in cap_names
    end

    test ":streaming_only returns streaming without tools" do
      caps = Fixtures.provider_capabilities(:streaming_only)

      cap_names = Enum.map(caps, & &1.name)
      assert "streaming" in cap_names
      assert "chat" in cap_names
      refute "tool_use" in cap_names
    end

    test ":no_interrupt returns capabilities without interrupt" do
      caps = Fixtures.provider_capabilities(:no_interrupt)

      cap_names = Enum.map(caps, & &1.name)
      assert "streaming" in cap_names
      refute "interrupt" in cap_names
    end

    test "all capabilities have valid types" do
      for preset <- [:full_claude, :minimal, :with_tools, :streaming_only, :no_interrupt] do
        caps = Fixtures.provider_capabilities(preset)

        assert Enum.all?(caps, fn cap ->
                 Capability.valid_type?(cap.type)
               end)
      end
    end
  end

  # ============================================================================
  # Golden Stream Tests
  # ============================================================================

  describe "golden_stream/2" do
    test ":simple_message returns correct event sequence" do
      events = Fixtures.golden_stream(:simple_message)

      assert length(events) == 4

      types = Enum.map(events, & &1.type)
      assert types == [:run_started, :message_received, :token_usage_updated, :run_completed]
    end

    test ":streaming_response returns streaming events" do
      events = Fixtures.golden_stream(:streaming_response)

      types = Enum.map(events, & &1.type)
      assert :message_streamed in types
      assert hd(types) == :run_started
      assert List.last(types) == :run_completed
    end

    test ":tool_use returns tool call events" do
      events = Fixtures.golden_stream(:tool_use)

      types = Enum.map(events, & &1.type)
      assert :tool_call_started in types
      assert :tool_call_completed in types
    end

    test ":multi_turn returns events for multiple runs" do
      events = Fixtures.golden_stream(:multi_turn)

      run_ids = events |> Enum.map(& &1.run_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)
      assert length(run_ids) == 2
    end

    test ":error_recovery includes error and recovery events" do
      events = Fixtures.golden_stream(:error_recovery)

      types = Enum.map(events, & &1.type)
      assert :error_occurred in types
      assert :error_recovered in types
      assert :run_completed in types
    end

    test ":cancelled_run includes cancellation event" do
      events = Fixtures.golden_stream(:cancelled_run)

      types = Enum.map(events, & &1.type)
      assert :run_cancelled in types
      assert :run_completed not in types
    end

    test ":rate_limited includes rate limit error" do
      events = Fixtures.golden_stream(:rate_limited)

      types = Enum.map(events, & &1.type)
      assert :error_occurred in types
      assert :run_failed in types
    end

    test ":session_lifecycle includes full session events" do
      events = Fixtures.golden_stream(:session_lifecycle)

      types = Enum.map(events, & &1.type)
      assert :session_created in types
      assert :session_started in types
      assert :run_started in types
      assert :run_completed in types
      assert :session_completed in types
    end

    test "golden streams accept custom session_id and run_id" do
      events =
        Fixtures.golden_stream(:simple_message,
          session_id: "custom_session",
          run_id: "custom_run"
        )

      assert Enum.all?(events, &(&1.session_id == "custom_session"))
      assert Enum.all?(events, &(&1.run_id == "custom_run"))
    end

    test "golden stream events have valid timestamps" do
      events = Fixtures.golden_stream(:simple_message)

      # All timestamps should be valid DateTimes
      assert Enum.all?(events, fn event ->
               %DateTime{} = event.timestamp
               true
             end)

      # Timestamps should be in order
      timestamps = Enum.map(events, & &1.timestamp)
      sorted = Enum.sort(timestamps, DateTime)
      assert timestamps == sorted
    end

    test "golden stream events have deterministic IDs" do
      events1 = Fixtures.golden_stream(:simple_message)
      events2 = Fixtures.golden_stream(:simple_message)

      ids1 = Enum.map(events1, & &1.id)
      ids2 = Enum.map(events2, & &1.id)

      assert ids1 == ids2
    end
  end

  # ============================================================================
  # Error Fixture Tests
  # ============================================================================

  describe "error/1" do
    test "returns errors with correct codes" do
      assert Fixtures.error(:validation_error).code == :validation_error
      assert Fixtures.error(:session_not_found).code == :session_not_found
      assert Fixtures.error(:run_not_found).code == :run_not_found
      assert Fixtures.error(:provider_error).code == :provider_error
      assert Fixtures.error(:provider_timeout).code == :provider_timeout
      assert Fixtures.error(:provider_rate_limited).code == :provider_rate_limited
      assert Fixtures.error(:cancelled).code == :cancelled
      assert Fixtures.error(:missing_required_capability).code == :missing_required_capability
    end

    test "rate_limited error includes provider details" do
      error = Fixtures.error(:provider_rate_limited)

      assert error.provider_error != nil
      assert error.provider_error.status_code == 429
      assert error.provider_error.retry_after == 30
    end
  end

  # ============================================================================
  # Execution Result Fixture Tests
  # ============================================================================

  describe "execution_result/1" do
    test ":successful returns valid result structure" do
      result = Fixtures.execution_result(:successful)

      assert is_map(result.output)
      assert is_map(result.token_usage)
      assert is_list(result.events)
      assert result.output.stop_reason == "end_turn"
    end

    test ":tool_use includes tool calls" do
      result = Fixtures.execution_result(:tool_use)

      assert result.output.stop_reason == "tool_use"
      assert length(result.output.tool_calls) == 1
      assert hd(result.output.tool_calls).name == "get_weather"
    end

    test ":empty_response has empty content" do
      result = Fixtures.execution_result(:empty_response)

      assert result.output.content == ""
      assert result.token_usage.output_tokens == 0
    end
  end

  # ============================================================================
  # Determinism Tests
  # ============================================================================

  describe "determinism" do
    test "same inputs produce same outputs" do
      # Build multiple times with same params
      sessions = for _ <- 1..5, do: Fixtures.build_session(index: 1, agent_id: "test")
      runs = for _ <- 1..5, do: Fixtures.build_run(index: 1, session_id: "ses")
      events = for _ <- 1..5, do: Fixtures.build_event(index: 1, type: :run_started)

      # All should be equal (except timestamps)
      assert length(Enum.uniq_by(sessions, & &1.id)) == 1
      assert length(Enum.uniq_by(runs, & &1.id)) == 1
      assert length(Enum.uniq_by(events, & &1.id)) == 1
    end
  end
end
