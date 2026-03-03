defmodule ASM.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias ASM.{Control, Event, Store}
  alias ASM.Store.Memory

  test "append_event/2 and list_events/2 persist ordered events per session" do
    assert {:ok, store} = Memory.start_link([])

    event1 = event("session-store-1", "run-1", :run_started)
    event2 = event("session-store-1", "run-1", :run_completed)

    assert :ok = Store.append_event(store, event1)
    assert :ok = Store.append_event(store, event2)

    assert {:ok, [^event1, ^event2]} = Store.list_events(store, "session-store-1")
  end

  test "append_event/2 is idempotent by event id" do
    assert {:ok, store} = Memory.start_link([])

    event = event("session-store-2", "run-1", :run_started)
    assert :ok = Store.append_event(store, event)
    assert :ok = Store.append_event(store, event)

    assert {:ok, events} = Store.list_events(store, "session-store-2")
    assert length(events) == 1
  end

  test "reset_session/2 clears a session without affecting others" do
    assert {:ok, store} = Memory.start_link([])

    event1 = event("session-a", "run-a", :run_started)
    event2 = event("session-b", "run-b", :run_started)

    assert :ok = Store.append_event(store, event1)
    assert :ok = Store.append_event(store, event2)
    assert :ok = Store.reset_session(store, "session-a")

    assert {:ok, []} = Store.list_events(store, "session-a")
    assert {:ok, [^event2]} = Store.list_events(store, "session-b")
  end

  defp event(session_id, run_id, kind) do
    payload =
      case kind do
        :run_started -> %Control.RunLifecycle{status: :started, summary: %{}}
        :run_completed -> %Control.RunLifecycle{status: :completed, summary: %{}}
      end

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
