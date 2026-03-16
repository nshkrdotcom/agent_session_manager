defmodule ASM.Extensions.PubSub.PipelineIntegrationTest do
  use ASM.TestCase

  alias ASM.{Event, Message, Run}
  alias ASM.Extensions.PubSub

  @receive_timeout 500

  test "pipeline plug broadcasts run events asynchronously without blocking run event fanout" do
    assert {:ok, broadcaster} =
             PubSub.start_broadcaster(
               adapter: {__MODULE__.SlowAdapter, delay_ms: 200, test_pid: self()},
               topic_scopes: [:run]
             )

    on_exit(fn -> if Process.alive?(broadcaster), do: GenServer.stop(broadcaster) end)

    run_id = "run-ext-pubsub-pipeline"
    session_id = "session-ext-pubsub-pipeline"

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: run_id,
               session_id: session_id,
               provider: :claude,
               subscriber: self(),
               pipeline: [PubSub.broadcaster_plug(broadcaster)]
             )

    assert_receive {:asm_run_event, ^run_id, %Event{kind: :run_started}}, @receive_timeout

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: run_id,
        session_id: session_id,
        provider: :claude,
        payload: %Message.Result{stop_reason: :end_turn},
        timestamp: DateTime.utc_now()
      }

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, ^run_id, %Event{kind: :result}}, 120
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 120
    assert_receive {:asm_run_done, ^run_id}

    assert :ok = PubSub.flush_broadcaster(broadcaster, 2_000)

    expected_topic = PubSub.run_topic(session_id, run_id)

    assert_receive {:slow_pubsub_broadcast, ^expected_topic,
                    {:asm_pubsub, ^expected_topic, payload}}

    assert payload.schema == "asm.pubsub.event.v1"
    assert payload.event.run_id == run_id
  end

  test "broadcaster drops overflowed events and continues draining" do
    assert {:ok, broadcaster} =
             PubSub.start_broadcaster(
               adapter: {__MODULE__.SlowAdapter, delay_ms: 100, test_pid: self()},
               topic_scopes: [:session],
               max_queue_size: 1,
               overflow: :drop_newest,
               notify: self()
             )

    on_exit(fn -> if Process.alive?(broadcaster), do: GenServer.stop(broadcaster) end)

    event1 = sample_event("session-ext-pubsub-overflow", "run-ext-pubsub-overflow", "a")
    event2 = sample_event("session-ext-pubsub-overflow", "run-ext-pubsub-overflow", "b")
    event3 = sample_event("session-ext-pubsub-overflow", "run-ext-pubsub-overflow", "c")

    assert :ok = PubSub.publish(broadcaster, event1)
    assert :ok = PubSub.publish(broadcaster, event2)
    assert :ok = PubSub.publish(broadcaster, event3)

    assert_receive(
      {:asm_pubsub_drop, %{reason: :queue_full, dropped_event_id: dropped_event_id}},
      @receive_timeout
    )

    assert dropped_event_id in [event2.id, event3.id]

    assert :ok = PubSub.flush_broadcaster(broadcaster, 2_000)

    assert_receive {:slow_pubsub_broadcast, _topic, _message}
  end

  defmodule SlowAdapter do
    @moduledoc false

    @behaviour ASM.Extensions.PubSub.Adapter

    @impl true
    def init(opts) do
      {:ok,
       %{
         delay_ms: Keyword.get(opts, :delay_ms, 100),
         test_pid: Keyword.fetch!(opts, :test_pid)
       }}
    end

    @impl true
    def broadcast(state, topic, message) do
      Process.sleep(state.delay_ms)
      send(state.test_pid, {:slow_pubsub_broadcast, topic, message})
      :ok
    end

    @impl true
    def subscribe(_state, _topic), do: :ok
  end

  defp sample_event(session_id, run_id, delta) do
    %Event{
      id: Event.generate_id(),
      kind: :assistant_delta,
      run_id: run_id,
      session_id: session_id,
      provider: :claude,
      payload: %Message.Partial{content_type: :text, delta: delta},
      timestamp: DateTime.utc_now()
    }
  end
end
