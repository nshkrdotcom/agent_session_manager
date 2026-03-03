defmodule ASM.Run.EventReducerTest do
  use ExUnit.Case, async: true

  alias ASM.{Event, Message, Run}

  test "assistant delta appends text and result finalizes run" do
    state =
      Run.State.new(
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude
      )

    delta_event =
      event(
        :assistant_delta,
        %Message.Partial{content_type: :text, delta: "hello "}
      )

    state = Run.EventReducer.apply_event!(state, delta_event)
    assert state.text_acc == "hello "
    assert state.sequence == 1

    result_event =
      event(
        :result,
        %Message.Result{stop_reason: :end_turn, duration_ms: 5, metadata: %{source: :test}}
      )

    state = Run.EventReducer.apply_event!(state, result_event)
    assert state.status == :completed
    assert Run.EventReducer.final?(state)

    result = Run.EventReducer.to_result(state)
    assert result.run_id == "run-1"
    assert result.text == "hello "
    assert result.stop_reason == :end_turn
  end

  test "error event marks run failed and final" do
    state = Run.State.new(run_id: "run-2", session_id: "session-2", provider: :gemini)

    error_event =
      event(
        :error,
        %Message.Error{severity: :error, message: "failed", kind: :unknown}
      )

    state = Run.EventReducer.apply_event!(state, error_event)
    assert state.status == :failed
    assert Run.EventReducer.final?(state)
  end

  defp event(kind, payload) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: "run-1",
      session_id: "session-1",
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end
end
