defmodule AgentSessionManager.Persistence.EventEmitterTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Persistence.EventEmitter

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "ses_event_emitter",
        run_id: "run_event_emitter",
        provider: "mock"
      },
      overrides
    )
  end

  describe "process/2" do
    test "builds, enriches, and validates event without persistence" do
      {:ok, event} =
        EventEmitter.process(%{type: "run_start", data: %{model: "mock-model"}}, context())

      assert event.type == :run_started
      assert event.session_id == "ses_event_emitter"
      assert event.run_id == "run_event_emitter"
      assert event.provider == "mock"
      assert event.sequence_number == nil
      assert event.data == %{model: "mock-model"}
      assert event.metadata[:provider] == "mock"
    end

    test "preserves adapter-provided timestamp" do
      ts = ~U[2025-06-15 12:00:00Z]
      {:ok, event} = EventEmitter.process(%{type: :run_started, timestamp: ts}, context())
      assert event.timestamp == ts
    end

    test "returns structural validation errors" do
      {:error, error} = EventEmitter.process(%{type: :run_started}, context(%{session_id: ""}))
      assert error.code == :validation_error
    end

    test "adds shape warnings to metadata for non-structural issues" do
      {:ok, event} = EventEmitter.process(%{type: :message_received, data: %{}}, context())
      assert is_list(event.metadata._validation_warnings)
      assert length(event.metadata._validation_warnings) == 2
    end
  end
end
