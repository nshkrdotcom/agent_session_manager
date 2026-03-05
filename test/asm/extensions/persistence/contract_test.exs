defmodule ASM.Extensions.Persistence.ContractTest do
  use ASM.TestCase

  alias ASM.{Control, Event, Message}
  alias ASM.Extensions.Persistence

  @store_kinds [:memory, :file]

  for store_kind <- @store_kinds do
    describe "#{store_kind} store contract" do
      setup context do
        {opts, cleanup_path} = store_setup_opts(unquote(store_kind), context)
        {:ok, store} = Persistence.start_store(unquote(store_kind), opts)

        on_exit(fn ->
          if Process.alive?(store), do: GenServer.stop(store)
          if cleanup_path, do: File.rm(cleanup_path)
        end)

        {:ok, store: store}
      end

      test "append_event/2 is idempotent and preserves first-write order", %{store: store} do
        first =
          lifecycle_event("session-ext-contract", "run-ext-contract", "event-ext-1", :started)

        second =
          lifecycle_event("session-ext-contract", "run-ext-contract", "event-ext-2", :completed)

        duplicate_first = %{
          first
          | payload: %Control.RunLifecycle{status: :completed, summary: %{}}
        }

        assert :ok = Persistence.append_event(store, first)
        assert :ok = Persistence.append_event(store, duplicate_first)
        assert :ok = Persistence.append_event(store, second)

        assert {:ok, events} = Persistence.list_events(store, "session-ext-contract")
        assert Enum.map(events, & &1.id) == [first.id, second.id]
        assert Enum.at(events, 0).payload.status == :started
      end

      test "replay_session/4 and rebuild_run/3 return correct projections", %{store: store} do
        run_events = [
          lifecycle_event("session-ext-replay", "run-ext-replay", "event-ext-r1", :started),
          text_delta_event("session-ext-replay", "run-ext-replay", "event-ext-r2", "persisted "),
          text_delta_event("session-ext-replay", "run-ext-replay", "event-ext-r3", "result"),
          result_event("session-ext-replay", "run-ext-replay", "event-ext-r4")
        ]

        Enum.each(run_events, fn event ->
          assert :ok = Persistence.append_event(store, event)
        end)

        assert {:ok, count} =
                 Persistence.replay_session(store, "session-ext-replay", 0, fn acc, _event ->
                   acc + 1
                 end)

        assert count == 4

        assert {:ok, %{events: rebuilt_events, result: result}} =
                 Persistence.rebuild_run(store, "session-ext-replay", "run-ext-replay")

        assert Enum.map(rebuilt_events, & &1.kind) ==
                 [:run_started, :assistant_delta, :assistant_delta, :result]

        assert result.run_id == "run-ext-replay"
        assert result.text == "persisted result"
        assert result.stop_reason == :end_turn
      end
    end
  end

  defp store_setup_opts(:memory, _context), do: {[], nil}

  defp store_setup_opts(:file, context) do
    test_name =
      context.test
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")

    path =
      Path.join(
        System.tmp_dir!(),
        "asm-ext-persistence-#{test_name}-#{System.unique_integer([:positive])}.events"
      )

    {[path: path], path}
  end

  defp lifecycle_event(session_id, run_id, event_id, status) do
    %Event{
      id: event_id,
      kind: status_to_kind(status),
      run_id: run_id,
      session_id: session_id,
      provider: :claude,
      payload: %Control.RunLifecycle{status: status, summary: %{}},
      timestamp: DateTime.utc_now()
    }
  end

  defp status_to_kind(:started), do: :run_started
  defp status_to_kind(:completed), do: :run_completed

  defp text_delta_event(session_id, run_id, event_id, delta) do
    %Event{
      id: event_id,
      kind: :assistant_delta,
      run_id: run_id,
      session_id: session_id,
      provider: :claude,
      payload: %Message.Partial{content_type: :text, delta: delta},
      timestamp: DateTime.utc_now()
    }
  end

  defp result_event(session_id, run_id, event_id) do
    %Event{
      id: event_id,
      kind: :result,
      run_id: run_id,
      session_id: session_id,
      provider: :claude,
      payload: %Message.Result{stop_reason: :end_turn},
      timestamp: DateTime.utc_now()
    }
  end
end
