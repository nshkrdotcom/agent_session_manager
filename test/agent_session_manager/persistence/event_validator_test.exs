defmodule AgentSessionManager.Persistence.EventValidatorTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.{Error, Event}
  alias AgentSessionManager.Persistence.EventValidator

  defp build_event(overrides \\ %{}) do
    defaults = %{
      id: "evt_test_#{System.unique_integer([:positive])}",
      type: :session_created,
      timestamp: DateTime.utc_now(),
      session_id: "ses_test",
      data: %{},
      metadata: %{},
      schema_version: 1
    }

    struct(Event, Map.merge(defaults, overrides))
  end

  # ============================================================================
  # Structural Validation
  # ============================================================================

  describe "validate_structural/1" do
    test "passes for a well-formed event" do
      event = build_event()
      assert :ok = EventValidator.validate_structural(event)
    end

    test "passes for all valid event types" do
      for type <- Event.all_types() do
        event = build_event(%{type: type})
        assert :ok = EventValidator.validate_structural(event), "Failed for type #{type}"
      end
    end

    test "rejects nil type" do
      event = build_event(%{type: nil})
      assert {:error, %Error{code: :validation_error}} = EventValidator.validate_structural(event)
    end

    test "rejects invalid event type" do
      event = build_event(%{type: :totally_bogus})

      assert {:error, %Error{code: :invalid_event_type}} =
               EventValidator.validate_structural(event)
    end

    test "rejects nil session_id" do
      event = build_event(%{session_id: nil})
      assert {:error, %Error{code: :validation_error}} = EventValidator.validate_structural(event)
    end

    test "rejects nil timestamp" do
      event = build_event(%{timestamp: nil})
      assert {:error, %Error{code: :validation_error}} = EventValidator.validate_structural(event)
    end

    test "rejects non-map data" do
      event = build_event(%{data: "not a map"})
      assert {:error, %Error{code: :validation_error}} = EventValidator.validate_structural(event)
    end

    test "accepts nil data (treated as empty)" do
      event = build_event(%{data: nil})
      assert :ok = EventValidator.validate_structural(event)
    end
  end

  # ============================================================================
  # Shape Validation
  # ============================================================================

  describe "validate_shape/1" do
    test "returns empty list for event types without shape rules" do
      for type <- [:session_created, :session_started, :session_completed, :run_started] do
        event = build_event(%{type: type, data: %{}})
        assert [] = EventValidator.validate_shape(event), "Expected no warnings for #{type}"
      end
    end

    test "returns empty list when data matches expected shape" do
      event =
        build_event(%{
          type: :message_received,
          data: %{content: "Hello", role: "assistant"}
        })

      assert [] = EventValidator.validate_shape(event)
    end

    test "warns on missing required field" do
      event = build_event(%{type: :message_received, data: %{role: "assistant"}})
      warnings = EventValidator.validate_shape(event)
      assert length(warnings) == 1
      assert hd(warnings) =~ "content"
    end

    test "warns on multiple missing fields" do
      event = build_event(%{type: :message_received, data: %{}})
      warnings = EventValidator.validate_shape(event)
      assert length(warnings) == 2
    end

    test "warns on wrong type" do
      event =
        build_event(%{
          type: :token_usage_updated,
          data: %{input_tokens: "not_a_number", output_tokens: 20}
        })

      warnings = EventValidator.validate_shape(event)
      assert length(warnings) == 1
      assert hd(warnings) =~ "input_tokens"
    end

    test "validates tool_call_started shape" do
      good = build_event(%{type: :tool_call_started, data: %{tool_name: "bash"}})
      assert [] = EventValidator.validate_shape(good)

      bad = build_event(%{type: :tool_call_started, data: %{}})
      assert [_ | _] = EventValidator.validate_shape(bad)
    end

    test "validates run_completed shape" do
      good = build_event(%{type: :run_completed, data: %{stop_reason: "end_turn"}})
      assert [] = EventValidator.validate_shape(good)

      bad = build_event(%{type: :run_completed, data: %{}})
      assert [_ | _] = EventValidator.validate_shape(bad)
    end

    test "validates error_occurred shape" do
      good = build_event(%{type: :error_occurred, data: %{error_message: "timeout"}})
      assert [] = EventValidator.validate_shape(good)

      bad = build_event(%{type: :error_occurred, data: %{}})
      assert [_ | _] = EventValidator.validate_shape(bad)
    end

    test "validates policy_violation shape" do
      good =
        build_event(%{
          type: :policy_violation,
          data: %{policy: "no_destructive", kind: "blocked"}
        })

      assert [] = EventValidator.validate_shape(good)

      bad = build_event(%{type: :policy_violation, data: %{}})
      warnings = EventValidator.validate_shape(bad)
      assert length(warnings) == 2
    end

    test "accepts string keys in data" do
      event =
        build_event(%{
          type: :message_received,
          data: %{"content" => "Hello", "role" => "assistant"}
        })

      assert [] = EventValidator.validate_shape(event)
    end
  end
end
