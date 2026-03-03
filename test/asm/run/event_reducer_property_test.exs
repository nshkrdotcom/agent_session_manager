defmodule ASM.Run.EventReducerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ASM.{Event, Message, Run}

  property "applying the same event stream twice yields identical run state" do
    check all(
            deltas <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                min_length: 1,
                max_length: 20
              ),
            include_result <- boolean()
          ) do
      initial = Run.State.new(run_id: "run-prop", session_id: "session-prop", provider: :claude)

      delta_events =
        deltas
        |> Enum.with_index(1)
        |> Enum.map(fn {delta, idx} ->
          %Event{
            id: "delta-#{idx}",
            kind: :assistant_delta,
            run_id: "run-prop",
            session_id: "session-prop",
            provider: :claude,
            payload: %Message.Partial{content_type: :text, delta: delta},
            timestamp: DateTime.from_unix!(idx, :second)
          }
        end)

      result_events =
        if include_result do
          [
            %Event{
              id: "result-1",
              kind: :result,
              run_id: "run-prop",
              session_id: "session-prop",
              provider: :claude,
              payload: %Message.Result{stop_reason: :end_turn},
              timestamp: DateTime.from_unix!(9_999, :second)
            }
          ]
        else
          []
        end

      events = delta_events ++ result_events

      state1 = Enum.reduce(events, initial, &Run.EventReducer.apply_event!(&2, &1))
      state2 = Enum.reduce(events, initial, &Run.EventReducer.apply_event!(&2, &1))

      assert state1 == state2
    end
  end
end
