defmodule ASM.HistoryTest do
  use ExUnit.Case, async: true

  alias ASM.{Event, History, Message, Store}
  alias ASM.Store.Memory

  test "replay_session/4 folds events with custom reducer" do
    assert {:ok, store} = Memory.start_link([])

    events = [
      event("session-history-1", "run-1", :run_started, nil),
      event("session-history-1", "run-1", :assistant_delta, %Message.Partial{
        content_type: :text,
        delta: "hi"
      }),
      event("session-history-1", "run-1", :result, %Message.Result{stop_reason: :end_turn})
    ]

    Enum.each(events, fn ev -> assert :ok = Store.append_event(store, ev) end)

    assert {:ok, count} =
             History.replay_session(store, "session-history-1", 0, fn acc, _event -> acc + 1 end)

    assert count == 3
  end

  test "rebuild_run/3 reconstructs run result from stored events" do
    assert {:ok, store} = Memory.start_link([])

    run_events = [
      event("session-history-2", "run-2", :run_started, nil),
      event("session-history-2", "run-2", :assistant_delta, %Message.Partial{
        content_type: :text,
        delta: "abc"
      }),
      event("session-history-2", "run-2", :result, %Message.Result{stop_reason: :end_turn})
    ]

    Enum.each(run_events, fn ev -> assert :ok = Store.append_event(store, ev) end)

    assert {:ok, %{result: result, state: state}} =
             History.rebuild_run(store, "session-history-2", "run-2")

    assert result.run_id == "run-2"
    assert result.text == "abc"
    assert result.stop_reason == :end_turn
    assert state.status == :completed
  end

  test "rebuild_run/3 returns typed error for missing run" do
    assert {:ok, store} = Memory.start_link([])
    assert {:error, error} = History.rebuild_run(store, "session-empty", "missing")
    assert error.kind == :unknown
    assert error.domain == :runtime
  end

  test "rebuild_run/3 projects non-negative duration for historical terminal events" do
    assert {:ok, store} = Memory.start_link([])

    old = DateTime.add(DateTime.utc_now(), -120, :second)

    assert :ok =
             Store.append_event(
               store,
               %Event{
                 id: Event.generate_id(),
                 kind: :error,
                 run_id: "run-old",
                 session_id: "session-old",
                 provider: :claude,
                 payload: %Message.Error{severity: :error, message: "boom", kind: :timeout},
                 timestamp: old
               }
             )

    assert {:ok, %{result: result}} = History.rebuild_run(store, "session-old", "run-old")
    assert is_integer(result.duration_ms)
    assert result.duration_ms >= 0
  end

  defp event(session_id, run_id, kind, payload) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: run_id,
      session_id: session_id,
      provider: :claude,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end
end
