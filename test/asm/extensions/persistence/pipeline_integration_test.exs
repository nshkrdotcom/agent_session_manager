defmodule ASM.Extensions.Persistence.PipelineIntegrationTest do
  use ASM.TestCase

  alias ASM.{Event, Message, Run}
  alias ASM.Extensions.Persistence

  @receive_timeout 500

  test "pipeline hook persists run events asynchronously and rebuilds run history" do
    assert {:ok, store} = Persistence.start_store(:memory, [])
    assert {:ok, writer} = Persistence.start_writer(store: store)
    on_exit(fn -> if Process.alive?(writer), do: GenServer.stop(writer) end)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-ext-pipe",
               session_id: "session-ext-pipe",
               provider: :claude,
               subscriber: self(),
               pipeline: [Persistence.writer_plug(writer)]
             )

    assert_receive {:asm_run_event, "run-ext-pipe", %Event{kind: :run_started}}, @receive_timeout

    delta_event =
      %Event{
        id: Event.generate_id(),
        kind: :assistant_delta,
        run_id: "run-ext-pipe",
        session_id: "session-ext-pipe",
        provider: :claude,
        payload: %Message.Partial{content_type: :text, delta: "hello persistence"},
        timestamp: DateTime.utc_now()
      }

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-ext-pipe",
        session_id: "session-ext-pipe",
        provider: :claude,
        payload: %Message.Result{stop_reason: :end_turn},
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, delta_event)
    assert_receive {:asm_run_event, "run-ext-pipe", %Event{kind: :assistant_delta}}

    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-ext-pipe", %Event{kind: :result}}
    assert_receive {:asm_run_done, "run-ext-pipe"}

    assert :ok = Persistence.flush_writer(writer)

    assert {:ok, persisted} = Persistence.list_events(store, "session-ext-pipe")
    assert Enum.map(persisted, & &1.kind) == [:assistant_delta, :result]

    assert {:ok, %{result: result}} =
             Persistence.rebuild_run(store, "session-ext-pipe", "run-ext-pipe")

    assert result.text == "hello persistence"
    assert result.stop_reason == :end_turn
  end

  test "slow persistence backend does not block run event emission path" do
    assert {:ok, store} = __MODULE__.SlowStore.start_link(delay_ms: 200)
    assert {:ok, writer} = Persistence.start_writer(store: store)
    on_exit(fn -> if Process.alive?(writer), do: GenServer.stop(writer) end)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-ext-slow-store",
               session_id: "session-ext-slow-store",
               provider: :claude,
               subscriber: self(),
               pipeline: [Persistence.writer_plug(writer)]
             )

    assert_receive {:asm_run_event, "run-ext-slow-store", %Event{kind: :run_started}},
                   @receive_timeout

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-ext-slow-store",
        session_id: "session-ext-slow-store",
        provider: :claude,
        payload: %Message.Result{
          stop_reason: :end_turn,
          usage: %{input_tokens: 1, output_tokens: 1}
        },
        timestamp: DateTime.utc_now()
      }

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-ext-slow-store", %Event{kind: :result}}, 120
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 120
    assert_receive {:asm_run_done, "run-ext-slow-store"}

    assert :ok = Persistence.flush_writer(writer, 2_000)
    assert {:ok, persisted} = Persistence.list_events(store, "session-ext-slow-store")
    assert Enum.map(persisted, & &1.kind) == [:result]
  end

  defmodule SlowStore do
    use GenServer

    alias ASM.{Error, Event, Store}

    @behaviour Store

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def append_event(store, event), do: Store.append_event(store, event)

    @impl true
    def list_events(store, session_id), do: Store.list_events(store, session_id)

    @impl true
    def reset_session(store, session_id), do: Store.reset_session(store, session_id)

    @impl true
    def init(opts) do
      {:ok,
       %{
         delay_ms: Keyword.get(opts, :delay_ms, 150),
         by_session: %{},
         by_session_event_ids: %{},
         seen_event_ids: MapSet.new()
       }}
    end

    @impl true
    def handle_call({:append_event, %Event{} = event}, _from, state) do
      Process.sleep(state.delay_ms)

      if MapSet.member?(state.seen_event_ids, event.id) do
        {:reply, :ok, state}
      else
        queue = Map.get(state.by_session, event.session_id, :queue.new())
        ids = Map.get(state.by_session_event_ids, event.session_id, MapSet.new())

        next_state = %{
          state
          | by_session: Map.put(state.by_session, event.session_id, :queue.in(event, queue)),
            by_session_event_ids:
              Map.put(state.by_session_event_ids, event.session_id, MapSet.put(ids, event.id)),
            seen_event_ids: MapSet.put(state.seen_event_ids, event.id)
        }

        {:reply, :ok, next_state}
      end
    end

    def handle_call({:list_events, session_id}, _from, state) do
      events =
        state.by_session
        |> Map.get(session_id, :queue.new())
        |> :queue.to_list()

      {:reply, {:ok, events}, state}
    end

    def handle_call({:reset_session, session_id}, _from, state) do
      seen_event_ids =
        state.by_session_event_ids
        |> Map.get(session_id, MapSet.new())
        |> Enum.reduce(state.seen_event_ids, fn event_id, acc ->
          MapSet.delete(acc, event_id)
        end)

      next_state = %{
        state
        | by_session: Map.delete(state.by_session, session_id),
          by_session_event_ids: Map.delete(state.by_session_event_ids, session_id),
          seen_event_ids: seen_event_ids
      }

      {:reply, :ok, next_state}
    end

    def handle_call(_other, _from, state) do
      {:reply, {:error, Error.new(:config_invalid, :config, "unsupported store operation")},
       state}
    end
  end
end
