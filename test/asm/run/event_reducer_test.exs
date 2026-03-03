defmodule ASM.Run.EventReducerTest do
  use ExUnit.Case, async: true

  alias ASM.{Control, Event, Message, Run}

  test "assistant delta appends text and result finalizes run" do
    state =
      Run.State.new(
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude
      )

    delta_event =
      event(
        "run-1",
        "session-1",
        :assistant_delta,
        %Message.Partial{content_type: :text, delta: "hello "}
      )

    state = Run.EventReducer.apply_event!(state, delta_event)
    state = Run.State.materialize(state)
    assert state.text_acc == "hello "
    assert state.sequence == 1

    result_event =
      event(
        "run-1",
        "session-1",
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

  test "error event marks run failed and captures a typed runtime error" do
    state = Run.State.new(run_id: "run-2", session_id: "session-2", provider: :gemini)

    error_event =
      event(
        "run-2",
        "session-2",
        :error,
        %Message.Error{severity: :error, message: "failed", kind: :tool_failed}
      )

    state = Run.EventReducer.apply_event!(state, error_event)
    assert state.status == :failed
    assert Run.EventReducer.final?(state)
    assert state.error.kind == :tool_failed
    assert state.error.domain == :runtime

    result = Run.EventReducer.to_result(state)
    assert result.error.kind == :tool_failed
    assert result.error.message == "failed"
  end

  test "cost_update events are accumulated and projected into result" do
    state = Run.State.new(run_id: "run-cost", session_id: "session-cost", provider: :claude)

    state =
      Run.EventReducer.apply_event!(
        state,
        event(
          "run-cost",
          "session-cost",
          :cost_update,
          %Control.CostUpdate{input_tokens: 2, output_tokens: 3, cost_usd: 0.8}
        )
      )

    state =
      Run.EventReducer.apply_event!(
        state,
        event(
          "run-cost",
          "session-cost",
          :cost_update,
          %Control.CostUpdate{input_tokens: 1, output_tokens: 2, cost_usd: 0.5}
        )
      )

    state =
      Run.EventReducer.apply_event!(
        state,
        event("run-cost", "session-cost", :result, %Message.Result{stop_reason: :end_turn})
      )

    assert state.cost == %{input_tokens: 3, output_tokens: 5, cost_usd: 1.3}

    result = Run.EventReducer.to_result(state)
    assert result.cost == %{input_tokens: 3, output_tokens: 5, cost_usd: 1.3}
  end

  defp event(run_id, session_id, kind, payload) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: run_id,
      session_id: session_id,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end
end
