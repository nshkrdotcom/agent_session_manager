defmodule AgentSessionManager.Persistence.EventBuilderTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Persistence.EventBuilder

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "ses_event_builder",
        run_id: "run_event_builder",
        provider: "mock"
      },
      overrides
    )
  end

  describe "process/2" do
    test "builds, enriches, and validates event without persistence" do
      {:ok, event} =
        EventBuilder.process(%{type: "run_started", data: %{model: "mock-model"}}, context())

      assert event.type == :run_started
      assert event.session_id == "ses_event_builder"
      assert event.run_id == "run_event_builder"
      assert event.provider == "mock"
      assert event.sequence_number == nil
      assert event.data == %{model: "mock-model"}
      refute Map.has_key?(event.metadata, :provider)
    end

    test "preserves adapter-provided timestamp" do
      ts = ~U[2025-06-15 12:00:00Z]
      {:ok, event} = EventBuilder.process(%{type: :run_started, timestamp: ts}, context())
      assert event.timestamp == ts
    end

    test "returns structural validation errors" do
      {:error, error} = EventBuilder.process(%{type: :run_started}, context(%{session_id: ""}))
      assert error.code == :validation_error
    end

    test "adds shape warnings to metadata for non-structural issues" do
      {:ok, event} = EventBuilder.process(%{type: :message_received, data: %{}}, context())
      assert is_list(event.metadata._validation_warnings)
      assert length(event.metadata._validation_warnings) == 2
    end
  end

  describe "process/2 with redaction" do
    test "redacts secrets when enabled via context override" do
      context =
        context(%{
          redaction: %{enabled: true, replacement: :categorized}
        })

      raw = %{
        type: :tool_call_completed,
        data: %{
          tool_name: "bash",
          tool_output: "Found key: AKIAIOSFODNN7EXAMPLE",
          tool_input: %{command: "env"}
        }
      }

      {:ok, event} = EventBuilder.process(raw, context)
      refute event.data.tool_output =~ "AKIAIOSFODNN7EXAMPLE"
      assert event.data.tool_output =~ "[REDACTED:aws_access_key]"
      assert event.data.tool_input == %{command: "env"}
    end

    test "passes through unchanged when redaction is disabled" do
      raw = %{
        type: :tool_call_completed,
        data: %{
          tool_name: "bash",
          tool_output: "key=AKIAIOSFODNN7EXAMPLE"
        }
      }

      {:ok, event} = EventBuilder.process(raw, context())
      assert event.data.tool_output =~ "AKIAIOSFODNN7EXAMPLE"
    end

    test "redaction does not interfere with validation" do
      context = context(%{redaction: %{enabled: true}})

      raw = %{
        type: :message_received,
        data: %{
          content: "Your key is ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL",
          role: "assistant"
        }
      }

      {:ok, event} = EventBuilder.process(raw, context)
      refute event.data.content =~ "ghp_"
      refute Map.has_key?(event.metadata, :_validation_warnings)
    end
  end
end
