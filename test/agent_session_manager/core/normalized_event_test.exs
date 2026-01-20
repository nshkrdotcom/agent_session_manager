defmodule AgentSessionManager.Core.NormalizedEventTest do
  @moduledoc """
  Tests for normalized event schema validation.

  These tests define the contract for normalized events - the canonical
  representation that all provider events are transformed into.

  Following TDD: these tests are written FIRST to specify the schema.
  """
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Core.NormalizedEvent

  describe "NormalizedEvent struct - required fields" do
    test "defines all required fields" do
      event = %NormalizedEvent{}

      # Core identity fields
      assert Map.has_key?(event, :id)
      assert Map.has_key?(event, :type)
      assert Map.has_key?(event, :timestamp)

      # Context fields (MUST be present per requirements)
      assert Map.has_key?(event, :session_id)
      assert Map.has_key?(event, :run_id)

      # Ordering fields
      assert Map.has_key?(event, :sequence_number)
      assert Map.has_key?(event, :parent_event_id)

      # Content fields
      assert Map.has_key?(event, :data)
      assert Map.has_key?(event, :metadata)

      # Source tracking
      assert Map.has_key?(event, :provider)
      assert Map.has_key?(event, :provider_event_id)
    end

    test "has sensible default values" do
      event = %NormalizedEvent{}

      assert event.data == %{}
      assert event.metadata == %{}
      assert event.sequence_number == nil
      assert event.parent_event_id == nil
    end
  end

  describe "NormalizedEvent.new/1 - schema validation" do
    test "creates event with all required fields" do
      attrs = %{
        type: :message_received,
        session_id: "ses_abc123",
        run_id: "run_xyz789",
        data: %{content: "Hello, world!"}
      }

      assert {:ok, event} = NormalizedEvent.new(attrs)

      assert event.type == :message_received
      assert event.session_id == "ses_abc123"
      assert event.run_id == "run_xyz789"
      assert event.data == %{content: "Hello, world!"}
      assert event.id != nil
      assert String.starts_with?(event.id, "nevt_")
      assert %DateTime{} = event.timestamp
    end

    test "requires session_id" do
      attrs = %{type: :message_received, run_id: "run_123"}

      assert {:error, %Error{code: :validation_error}} = NormalizedEvent.new(attrs)
    end

    test "requires run_id" do
      attrs = %{type: :message_received, session_id: "ses_123"}

      assert {:error, %Error{code: :validation_error}} = NormalizedEvent.new(attrs)
    end

    test "requires type" do
      attrs = %{session_id: "ses_123", run_id: "run_123"}

      assert {:error, %Error{code: :validation_error}} = NormalizedEvent.new(attrs)
    end

    test "validates event type" do
      attrs = %{
        type: :invalid_type_that_does_not_exist,
        session_id: "ses_123",
        run_id: "run_123"
      }

      assert {:error, %Error{code: :invalid_event_type}} = NormalizedEvent.new(attrs)
    end

    test "rejects empty session_id" do
      attrs = %{type: :message_received, session_id: "", run_id: "run_123"}

      assert {:error, %Error{code: :validation_error}} = NormalizedEvent.new(attrs)
    end

    test "rejects empty run_id" do
      attrs = %{type: :message_received, session_id: "ses_123", run_id: ""}

      assert {:error, %Error{code: :validation_error}} = NormalizedEvent.new(attrs)
    end

    test "accepts optional sequence_number" do
      attrs = %{
        type: :message_streamed,
        session_id: "ses_123",
        run_id: "run_123",
        sequence_number: 42
      }

      assert {:ok, event} = NormalizedEvent.new(attrs)
      assert event.sequence_number == 42
    end

    test "accepts optional parent_event_id for causal ordering" do
      attrs = %{
        type: :tool_call_completed,
        session_id: "ses_123",
        run_id: "run_123",
        parent_event_id: "nevt_parent123"
      }

      assert {:ok, event} = NormalizedEvent.new(attrs)
      assert event.parent_event_id == "nevt_parent123"
    end

    test "accepts provider tracking fields" do
      attrs = %{
        type: :message_received,
        session_id: "ses_123",
        run_id: "run_123",
        provider: :anthropic,
        provider_event_id: "msg_01XYZ"
      }

      assert {:ok, event} = NormalizedEvent.new(attrs)
      assert event.provider == :anthropic
      assert event.provider_event_id == "msg_01XYZ"
    end

    test "generates unique IDs" do
      attrs = %{type: :message_received, session_id: "ses_123", run_id: "run_123"}

      {:ok, event1} = NormalizedEvent.new(attrs)
      {:ok, event2} = NormalizedEvent.new(attrs)

      refute event1.id == event2.id
    end

    test "allows custom ID" do
      attrs = %{
        id: "custom_event_id",
        type: :message_received,
        session_id: "ses_123",
        run_id: "run_123"
      }

      assert {:ok, event} = NormalizedEvent.new(attrs)
      assert event.id == "custom_event_id"
    end
  end

  describe "NormalizedEvent - all valid event types" do
    @session_events [
      :session_created,
      :session_started,
      :session_paused,
      :session_resumed,
      :session_completed,
      :session_failed,
      :session_cancelled
    ]

    @run_events [
      :run_started,
      :run_completed,
      :run_failed,
      :run_cancelled,
      :run_timeout
    ]

    @message_events [
      :message_sent,
      :message_received,
      :message_streamed
    ]

    @tool_events [
      :tool_call_started,
      :tool_call_completed,
      :tool_call_failed
    ]

    @error_events [
      :error_occurred,
      :error_recovered
    ]

    @usage_events [
      :token_usage_updated,
      :turn_completed
    ]

    for event_type <-
          @session_events ++
            @run_events ++ @message_events ++ @tool_events ++ @error_events ++ @usage_events do
      test "accepts event type #{event_type}" do
        attrs = %{
          type: unquote(event_type),
          session_id: "ses_123",
          run_id: "run_123"
        }

        assert {:ok, event} = NormalizedEvent.new(attrs)
        assert event.type == unquote(event_type)
      end
    end
  end

  describe "NormalizedEvent.to_map/1 - serialization" do
    test "converts event to map with string keys" do
      {:ok, event} =
        NormalizedEvent.new(%{
          type: :message_received,
          session_id: "ses_123",
          run_id: "run_123",
          sequence_number: 5,
          data: %{content: "Hello"},
          metadata: %{source: "test"},
          provider: :openai,
          provider_event_id: "chatcmpl-123"
        })

      map = NormalizedEvent.to_map(event)

      assert is_map(map)
      assert map["id"] == event.id
      assert map["type"] == "message_received"
      assert map["session_id"] == "ses_123"
      assert map["run_id"] == "run_123"
      assert map["sequence_number"] == 5
      assert map["data"] == %{"content" => "Hello"}
      assert map["metadata"] == %{"source" => "test"}
      assert map["provider"] == "openai"
      assert map["provider_event_id"] == "chatcmpl-123"
      assert is_binary(map["timestamp"])
    end

    test "handles nil optional fields" do
      {:ok, event} =
        NormalizedEvent.new(%{
          type: :run_started,
          session_id: "ses_123",
          run_id: "run_123"
        })

      map = NormalizedEvent.to_map(event)

      assert map["parent_event_id"] == nil
      assert map["provider"] == nil
      assert map["provider_event_id"] == nil
    end
  end

  describe "NormalizedEvent.from_map/1 - deserialization" do
    test "reconstructs event from map" do
      {:ok, original} =
        NormalizedEvent.new(%{
          type: :message_received,
          session_id: "ses_123",
          run_id: "run_123",
          sequence_number: 10,
          data: %{content: "Test"},
          provider: :anthropic
        })

      map = NormalizedEvent.to_map(original)
      {:ok, restored} = NormalizedEvent.from_map(map)

      assert restored.id == original.id
      assert restored.type == original.type
      assert restored.session_id == original.session_id
      assert restored.run_id == original.run_id
      assert restored.sequence_number == original.sequence_number
      assert restored.data == original.data
      assert restored.provider == original.provider
    end

    test "returns error for missing required fields" do
      assert {:error, %Error{code: :validation_error}} = NormalizedEvent.from_map(%{})

      assert {:error, %Error{}} =
               NormalizedEvent.from_map(%{
                 "id" => "test",
                 "type" => "message_received",
                 "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
                 # missing session_id, run_id
               })
    end

    test "returns error for invalid type" do
      assert {:error, %Error{code: :invalid_event_type}} =
               NormalizedEvent.from_map(%{
                 "id" => "test",
                 "type" => "not_a_real_type",
                 "session_id" => "ses_123",
                 "run_id" => "run_123",
                 "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
               })
    end
  end

  describe "NormalizedEvent - comparison and validation" do
    test "valid?/1 returns true for valid events" do
      {:ok, event} =
        NormalizedEvent.new(%{
          type: :message_received,
          session_id: "ses_123",
          run_id: "run_123"
        })

      assert NormalizedEvent.valid?(event)
    end

    test "valid?/1 returns false for invalid struct" do
      # Direct struct creation bypassing validation
      invalid = %NormalizedEvent{
        id: nil,
        type: nil,
        session_id: nil,
        run_id: nil,
        timestamp: nil
      }

      refute NormalizedEvent.valid?(invalid)
    end

    test "same_context?/2 compares session and run" do
      {:ok, event1} =
        NormalizedEvent.new(%{
          type: :message_sent,
          session_id: "ses_123",
          run_id: "run_456"
        })

      {:ok, event2} =
        NormalizedEvent.new(%{
          type: :message_received,
          session_id: "ses_123",
          run_id: "run_456"
        })

      {:ok, event3} =
        NormalizedEvent.new(%{
          type: :message_received,
          session_id: "ses_999",
          run_id: "run_456"
        })

      assert NormalizedEvent.same_context?(event1, event2)
      refute NormalizedEvent.same_context?(event1, event3)
    end
  end
end
