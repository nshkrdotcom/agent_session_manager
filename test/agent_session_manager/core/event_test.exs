defmodule AgentSessionManager.Core.EventTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Event

  describe "Event struct" do
    test "defines required fields" do
      event = %Event{}

      assert Map.has_key?(event, :id)
      assert Map.has_key?(event, :type)
      assert Map.has_key?(event, :timestamp)
      assert Map.has_key?(event, :session_id)
      assert Map.has_key?(event, :run_id)
    end

    test "defines optional fields" do
      event = %Event{}

      assert Map.has_key?(event, :data)
      assert Map.has_key?(event, :metadata)
      assert Map.has_key?(event, :sequence_number)
    end

    test "has default values" do
      event = %Event{}

      assert event.data == %{}
      assert event.metadata == %{}
      assert event.sequence_number == nil
    end
  end

  describe "Event types enumeration" do
    test "session lifecycle events are valid" do
      session_events = [
        :session_created,
        :session_started,
        :session_paused,
        :session_resumed,
        :session_completed,
        :session_failed,
        :session_cancelled
      ]

      for event_type <- session_events do
        assert Event.valid_type?(event_type),
               "Expected #{event_type} to be a valid event type"
      end
    end

    test "run lifecycle events are valid" do
      run_events = [
        :run_started,
        :run_completed,
        :run_failed,
        :run_cancelled,
        :run_timeout
      ]

      for event_type <- run_events do
        assert Event.valid_type?(event_type),
               "Expected #{event_type} to be a valid event type"
      end
    end

    test "message events are valid" do
      message_events = [
        :message_sent,
        :message_received,
        :message_streamed
      ]

      for event_type <- message_events do
        assert Event.valid_type?(event_type),
               "Expected #{event_type} to be a valid event type"
      end
    end

    test "tool events are valid" do
      tool_events = [
        :tool_call_started,
        :tool_call_completed,
        :tool_call_failed
      ]

      for event_type <- tool_events do
        assert Event.valid_type?(event_type),
               "Expected #{event_type} to be a valid event type"
      end
    end

    test "error events are valid" do
      error_events = [
        :error_occurred,
        :error_recovered
      ]

      for event_type <- error_events do
        assert Event.valid_type?(event_type),
               "Expected #{event_type} to be a valid event type"
      end
    end

    test "token/usage events are valid" do
      usage_events = [
        :token_usage_updated,
        :turn_completed
      ]

      for event_type <- usage_events do
        assert Event.valid_type?(event_type),
               "Expected #{event_type} to be a valid event type"
      end
    end

    test "policy violation events are valid" do
      assert Event.valid_type?(:policy_violation)
    end

    test "invalid event types are rejected" do
      refute Event.valid_type?(:invalid_event_type)
      refute Event.valid_type?(:unknown)
      refute Event.valid_type?("string_type")
    end

    test "all_types/0 returns list of all valid event types" do
      types = Event.all_types()

      assert is_list(types)
      refute Enum.empty?(types)
      assert :session_created in types
      assert :run_started in types
      assert :message_sent in types
      assert :tool_call_started in types
      assert :error_occurred in types
      assert :policy_violation in types
    end
  end

  describe "Event.new/1" do
    test "creates an event with required fields" do
      {:ok, event} =
        Event.new(%{
          type: :session_created,
          session_id: "session-123"
        })

      assert event.type == :session_created
      assert event.session_id == "session-123"
      assert event.id != nil
      assert is_binary(event.id)
      assert event.timestamp != nil
    end

    test "generates a unique ID" do
      {:ok, event1} = Event.new(%{type: :session_created, session_id: "session-123"})
      {:ok, event2} = Event.new(%{type: :session_created, session_id: "session-123"})

      refute event1.id == event2.id
    end

    test "allows custom ID" do
      {:ok, event} =
        Event.new(%{
          id: "custom-event-id",
          type: :session_created,
          session_id: "session-123"
        })

      assert event.id == "custom-event-id"
    end

    test "accepts run_id for run-scoped events" do
      {:ok, event} =
        Event.new(%{
          type: :run_started,
          session_id: "session-123",
          run_id: "run-456"
        })

      assert event.run_id == "run-456"
    end

    test "accepts data payload" do
      {:ok, event} =
        Event.new(%{
          type: :message_received,
          session_id: "session-123",
          data: %{content: "Hello!", role: "assistant"}
        })

      assert event.data == %{content: "Hello!", role: "assistant"}
    end

    test "accepts metadata" do
      {:ok, event} =
        Event.new(%{
          type: :session_created,
          session_id: "session-123",
          metadata: %{source: "api", version: "1.0"}
        })

      assert event.metadata == %{source: "api", version: "1.0"}
    end

    test "accepts sequence_number" do
      {:ok, event} =
        Event.new(%{
          type: :message_streamed,
          session_id: "session-123",
          sequence_number: 42
        })

      assert event.sequence_number == 42
    end

    test "returns error when type is missing" do
      result = Event.new(%{session_id: "session-123"})

      assert {:error, error} = result
      assert error.code == :validation_error
      assert error.message =~ "type"
    end

    test "returns error when type is invalid" do
      result = Event.new(%{type: :invalid_type, session_id: "session-123"})

      assert {:error, error} = result
      assert error.code == :invalid_event_type
    end

    test "returns error when session_id is missing" do
      result = Event.new(%{type: :session_created})

      assert {:error, error} = result
      assert error.code == :validation_error
      assert error.message =~ "session_id"
    end
  end

  describe "Event.to_map/1" do
    test "converts event to a map for JSON serialization" do
      {:ok, event} =
        Event.new(%{
          type: :message_received,
          session_id: "session-123",
          run_id: "run-456",
          data: %{content: "Hello!"},
          sequence_number: 1
        })

      map = Event.to_map(event)

      assert is_map(map)
      assert map["id"] == event.id
      assert map["type"] == "message_received"
      assert map["session_id"] == "session-123"
      assert map["run_id"] == "run-456"
      assert map["data"] == %{"content" => "Hello!"}
      assert map["sequence_number"] == 1
      assert is_binary(map["timestamp"])
    end
  end

  describe "Event.from_map/1" do
    test "reconstructs an event from a map" do
      {:ok, original} =
        Event.new(%{
          type: :message_received,
          session_id: "session-123",
          run_id: "run-456",
          data: %{content: "Hello!"}
        })

      map = Event.to_map(original)
      {:ok, restored} = Event.from_map(map)

      assert restored.id == original.id
      assert restored.type == original.type
      assert restored.session_id == original.session_id
      assert restored.run_id == original.run_id
      assert restored.data == original.data
    end

    test "returns error for invalid map" do
      result = Event.from_map(%{})

      assert {:error, error} = result
      assert error.code == :validation_error
    end

    test "returns error for invalid type in map" do
      result =
        Event.from_map(%{
          "id" => "event-123",
          "type" => "invalid_type",
          "session_id" => "session-123",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert {:error, error} = result
      assert error.code == :invalid_event_type
    end
  end

  describe "Event schema versioning" do
    test "new events get schema_version 1 by default" do
      {:ok, event} =
        Event.new(%{
          type: :session_created,
          session_id: "session-123"
        })

      assert event.schema_version == 1
    end

    test "schema_version is preserved when explicitly set" do
      {:ok, event} =
        Event.new(%{
          type: :session_created,
          session_id: "session-123",
          schema_version: 2
        })

      assert event.schema_version == 2
    end

    test "events without schema_version (nil) are backward compatible" do
      # Simulate an old event struct without schema_version
      event = %Event{
        id: "evt_old",
        type: :session_created,
        session_id: "session-123",
        timestamp: DateTime.utc_now(),
        schema_version: nil
      }

      # The struct should still work
      assert event.id == "evt_old"
      assert event.type == :session_created
      assert event.schema_version == nil
    end

    test "schema_version is included in to_map serialization" do
      {:ok, event} =
        Event.new(%{
          type: :session_created,
          session_id: "session-123"
        })

      map = Event.to_map(event)
      assert map["schema_version"] == 1
    end

    test "schema_version is restored from from_map deserialization" do
      {:ok, original} =
        Event.new(%{
          type: :session_created,
          session_id: "session-123"
        })

      map = Event.to_map(original)
      {:ok, restored} = Event.from_map(map)

      assert restored.schema_version == 1
    end

    test "from_map defaults schema_version to 1 when missing" do
      map = %{
        "id" => "evt_old",
        "type" => "session_created",
        "session_id" => "session-123",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, event} = Event.from_map(map)
      assert event.schema_version == 1
    end

    test "struct default for schema_version is 1" do
      event = %Event{}
      assert event.schema_version == 1
    end
  end

  describe "Event type categories" do
    test "session_events/0 returns session lifecycle event types" do
      types = Event.session_events()

      assert :session_created in types
      assert :session_started in types
      assert :session_completed in types
      assert :session_failed in types
      refute :run_started in types
      refute :message_sent in types
    end

    test "run_events/0 returns run lifecycle event types" do
      types = Event.run_events()

      assert :run_started in types
      assert :run_completed in types
      assert :run_failed in types
      refute :session_created in types
      refute :message_sent in types
    end

    test "message_events/0 returns message event types" do
      types = Event.message_events()

      assert :message_sent in types
      assert :message_received in types
      assert :message_streamed in types
      refute :session_created in types
    end

    test "tool_events/0 returns tool call event types" do
      types = Event.tool_events()

      assert :tool_call_started in types
      assert :tool_call_completed in types
      assert :tool_call_failed in types
      refute :session_created in types
    end

    test "error_events/0 returns error event types" do
      types = Event.error_events()

      assert :error_occurred in types
      assert :error_recovered in types
      refute :session_created in types
    end
  end
end
