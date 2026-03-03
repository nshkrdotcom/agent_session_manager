defmodule ASM.Store.IdempotencyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ASM.{Control, Event, Store}
  alias ASM.Store.Memory

  property "append_event/2 is idempotent by event id and preserves first-write order" do
    check all(ids <- list_of(integer(1..10), min_length: 1, max_length: 40)) do
      {:ok, store} = Memory.start_link([])

      events =
        ids
        |> Enum.map(fn id ->
          %Event{
            id: "event-#{id}",
            kind: :run_started,
            run_id: "run-#{id}",
            session_id: "session-store-prop",
            provider: :claude,
            payload: %Control.RunLifecycle{status: :started, summary: %{}},
            timestamp: DateTime.utc_now()
          }
        end)

      # Append duplicates in two passes to enforce idempotency behavior.
      Enum.each(events ++ Enum.reverse(events), fn event ->
        assert :ok = Store.append_event(store, event)
      end)

      expected_ids =
        events
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(& &1.id)

      assert {:ok, stored} = Store.list_events(store, "session-store-prop")
      assert Enum.map(stored, & &1.id) == expected_ids
    end
  end
end
