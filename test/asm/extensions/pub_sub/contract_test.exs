defmodule ASM.Extensions.PubSub.ContractTest do
  use ASM.TestCase

  alias ASM.{Error, Event}
  alias ASM.Extensions.PubSub

  test "topics_for_event/2 returns canonical all/session/run routing" do
    event = sample_event("session-ext-pubsub-topics", "run-ext-pubsub-topics")

    assert {:ok, topics} =
             PubSub.topics_for_event(event,
               scopes: [:all, :session, :run],
               prefix: "asm"
             )

    assert topics == [
             "asm:events",
             "asm:session:session-ext-pubsub-topics",
             "asm:session:session-ext-pubsub-topics:run:run-ext-pubsub-topics"
           ]
  end

  test "local adapter broadcasts payload contract to subscribed topics" do
    adapter = PubSub.local_adapter(auto_start: true)

    assert {:ok, broadcaster} =
             PubSub.start_broadcaster(adapter: adapter, topic_scopes: [:session, :run])

    on_exit(fn ->
      if Process.alive?(broadcaster), do: GenServer.stop(broadcaster)
    end)

    event = sample_event("session-ext-pubsub-delivery", "run-ext-pubsub-delivery")

    session_topic = PubSub.session_topic(event.session_id)
    run_topic = PubSub.run_topic(event.session_id, event.run_id)

    assert :ok = PubSub.subscribe(adapter, session_topic)
    assert :ok = PubSub.subscribe(adapter, run_topic)

    assert :ok = PubSub.publish(broadcaster, event)
    assert :ok = PubSub.flush_broadcaster(broadcaster)

    assert_receive {:asm_pubsub, ^session_topic, session_payload}
    assert session_payload.schema == "asm.pubsub.event.v1"
    assert session_payload.event.id == event.id
    assert session_payload.meta.event_kind == :assistant_delta

    assert_receive {:asm_pubsub, ^run_topic, run_payload}
    assert run_payload.schema == "asm.pubsub.event.v1"
    assert run_payload.event.run_id == event.run_id
  end

  test "event_callback/2 forwards events through broadcaster" do
    adapter = PubSub.local_adapter(auto_start: true)

    assert {:ok, broadcaster} =
             PubSub.start_broadcaster(adapter: adapter, topic_scopes: [:session])

    on_exit(fn ->
      if Process.alive?(broadcaster), do: GenServer.stop(broadcaster)
    end)

    event = sample_event("session-ext-pubsub-callback", "run-ext-pubsub-callback")
    topic = PubSub.session_topic(event.session_id)

    assert :ok = PubSub.subscribe(adapter, topic)

    callback = PubSub.event_callback(broadcaster)
    assert :ok = callback.(event, "ignored iodata")
    assert :ok = PubSub.flush_broadcaster(broadcaster)

    assert_receive {:asm_pubsub, ^topic, payload}
    assert payload.event.id == event.id
  end

  test "phoenix adapter returns explicit error when optional dependency module is unavailable" do
    missing_module = Module.concat([ASM.Extensions.PubSub, MissingPhoenixPubSub])

    assert {:error, %Error{} = error} =
             PubSub.subscribe(
               PubSub.phoenix_adapter(
                 name: :asm_missing_pubsub,
                 pubsub_module: missing_module
               ),
               PubSub.all_topic()
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "optional dependency"
  end

  defp sample_event(session_id, run_id) do
    %Event{
      id: Event.generate_id(),
      kind: :assistant_delta,
      run_id: run_id,
      session_id: session_id,
      provider: :claude,
      payload: %ASM.Message.Partial{content_type: :text, delta: "pubsub"},
      timestamp: DateTime.utc_now()
    }
  end
end
