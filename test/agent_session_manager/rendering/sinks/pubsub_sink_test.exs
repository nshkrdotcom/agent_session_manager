defmodule AgentSessionManager.Rendering.Sinks.PubSubSinkTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Sinks.PubSubSink
  import AgentSessionManager.Test.RenderingHelpers

  # Mock dispatcher that sends to the test process (the :pubsub value is used as the target pid)
  defmodule MockDispatcher do
    def broadcast(pubsub, topic, message) do
      send(pubsub, {:broadcast, topic, message})
      :ok
    end
  end

  defmodule FailingDispatcher do
    def broadcast(_pubsub, _topic, _message) do
      {:error, :no_subscribers}
    end
  end

  describe "init/1" do
    test "requires :pubsub option" do
      assert {:error, _} = PubSubSink.init([])
    end

    test "requires :pubsub option even with other opts" do
      assert {:error, _} = PubSubSink.init(topic: "test")
    end

    test "accepts static topic" do
      assert {:ok, state} =
               PubSubSink.init(
                 pubsub: self(),
                 topic: "test:events",
                 dispatcher: MockDispatcher
               )

      assert is_map(state)
    end

    test "accepts topic_fn" do
      assert {:ok, _} =
               PubSubSink.init(
                 pubsub: self(),
                 topic_fn: fn _event -> "dynamic" end,
                 dispatcher: MockDispatcher
               )
    end

    test "rejects :topic and :topic_fn together" do
      assert {:error, _} =
               PubSubSink.init(
                 pubsub: self(),
                 topic: "t",
                 topic_fn: &Function.identity/1,
                 dispatcher: MockDispatcher
               )
    end

    test "rejects non-1-arity :topic_fn" do
      assert {:error, _} =
               PubSubSink.init(
                 pubsub: self(),
                 topic_fn: fn _a, _b -> "bad" end,
                 dispatcher: MockDispatcher
               )
    end

    test "defaults to session-scoped topic strategy" do
      assert {:ok, state} =
               PubSubSink.init(pubsub: self(), dispatcher: MockDispatcher)

      assert state.topic_strategy == {:scoped, "asm", :session}
    end

    test "respects custom prefix" do
      assert {:ok, state} =
               PubSubSink.init(pubsub: self(), prefix: "myapp", dispatcher: MockDispatcher)

      assert state.topic_strategy == {:scoped, "myapp", :session}
    end

    test "respects custom scope" do
      assert {:ok, state} =
               PubSubSink.init(pubsub: self(), scope: :run, dispatcher: MockDispatcher)

      assert state.topic_strategy == {:scoped, "asm", :run}
    end

    test "defaults message_wrapper to :asm_event" do
      assert {:ok, state} =
               PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      assert state.message_wrapper == :asm_event
    end

    test "accepts custom message_wrapper" do
      assert {:ok, state} =
               PubSubSink.init(
                 pubsub: self(),
                 topic: "t",
                 message_wrapper: :agent_event,
                 dispatcher: MockDispatcher
               )

      assert state.message_wrapper == :agent_event
    end

    test "defaults include_iodata to false" do
      assert {:ok, state} =
               PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      assert state.include_iodata == false
    end

    test "initializes counters to zero" do
      assert {:ok, state} =
               PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      assert state.broadcast_count == 0
      assert state.error_count == 0
    end
  end

  describe "write/2" do
    test "is a no-op that returns state unchanged" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      assert {:ok, ^state} = PubSubSink.write("some rendered text", state)
      refute_received {:broadcast, _, _}
    end
  end

  describe "write_event/3 with static topic" do
    test "broadcasts event to static topic" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "my:topic", dispatcher: MockDispatcher)

      event = run_started()

      {:ok, _state} = PubSubSink.write_event(event, [], state)

      assert_received {:broadcast, "my:topic", {:asm_event, _, ^event}}
    end

    test "includes session_id in broadcast tuple" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      event = run_started()
      session_id = event[:session_id]

      {:ok, _state} = PubSubSink.write_event(event, [], state)

      assert_received {:broadcast, "t", {:asm_event, ^session_id, ^event}}
    end

    test "increments broadcast_count on success" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      {:ok, state} = PubSubSink.write_event(run_started(), [], state)
      assert state.broadcast_count == 1

      {:ok, state} = PubSubSink.write_event(message_streamed("hi"), [], state)
      assert state.broadcast_count == 2
    end
  end

  describe "write_event/3 with scoped topics" do
    test "broadcasts to session-scoped topic" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), scope: :session, dispatcher: MockDispatcher)

      event = run_started()
      {:ok, _state} = PubSubSink.write_event(event, [], state)

      expected_topic = "asm:session:#{event[:session_id]}"
      assert_received {:broadcast, ^expected_topic, _}
    end

    test "broadcasts to run-scoped topic" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), scope: :run, dispatcher: MockDispatcher)

      event = run_started()
      {:ok, _state} = PubSubSink.write_event(event, [], state)

      expected_topic = "asm:session:#{event[:session_id]}:run:#{event[:run_id]}"
      assert_received {:broadcast, ^expected_topic, _}
    end

    test "broadcasts with custom prefix" do
      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          prefix: "myapp",
          scope: :session,
          dispatcher: MockDispatcher
        )

      event = run_started()
      {:ok, _state} = PubSubSink.write_event(event, [], state)

      expected_topic = "myapp:session:#{event[:session_id]}"
      assert_received {:broadcast, ^expected_topic, _}
    end
  end

  describe "write_event/3 with topic_fn" do
    test "broadcasts to single dynamic topic" do
      topic_fn = fn _event -> "dynamic:topic" end

      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          topic_fn: topic_fn,
          dispatcher: MockDispatcher
        )

      event = run_started()
      {:ok, _state} = PubSubSink.write_event(event, [], state)

      assert_received {:broadcast, "dynamic:topic", _}
    end

    test "broadcasts to multiple topics from topic_fn returning a list" do
      topic_fn = fn _event -> ["topic:a", "topic:b"] end

      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          topic_fn: topic_fn,
          dispatcher: MockDispatcher
        )

      event = run_started()
      {:ok, state} = PubSubSink.write_event(event, [], state)

      assert_received {:broadcast, "topic:a", _}
      assert_received {:broadcast, "topic:b", _}
      assert state.broadcast_count == 2
    end

    test "topic_fn receives the event" do
      test_pid = self()

      topic_fn = fn event ->
        send(test_pid, {:topic_fn_called, event.type})
        "dynamic"
      end

      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          topic_fn: topic_fn,
          dispatcher: MockDispatcher
        )

      event = run_started()
      {:ok, _state} = PubSubSink.write_event(event, [], state)

      assert_received {:topic_fn_called, :run_started}
    end
  end

  describe "write_event/3 with include_iodata" do
    test "excludes iodata by default (3-tuple message)" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      event = run_started()
      iodata = ["rendered text"]

      {:ok, _} = PubSubSink.write_event(event, iodata, state)

      assert_received {:broadcast, "t", {:asm_event, _, ^event}}
    end

    test "includes iodata when configured (4-tuple message)" do
      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          topic: "t",
          include_iodata: true,
          dispatcher: MockDispatcher
        )

      event = run_started()
      iodata = ["rendered text"]

      {:ok, _} = PubSubSink.write_event(event, iodata, state)

      assert_received {:broadcast, "t", {:asm_event, _, ^event, ^iodata}}
    end
  end

  describe "write_event/3 with custom message_wrapper" do
    test "uses custom wrapper atom" do
      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          topic: "t",
          message_wrapper: :agent_event,
          dispatcher: MockDispatcher
        )

      event = run_started()
      {:ok, _} = PubSubSink.write_event(event, [], state)

      assert_received {:broadcast, "t", {:agent_event, _, ^event}}
    end
  end

  describe "write_event/3 error handling" do
    test "tracks error count on broadcast failure" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: FailingDispatcher)

      event = run_started()
      {:ok, state} = PubSubSink.write_event(event, [], state)

      assert state.error_count == 1
      assert state.broadcast_count == 0
    end

    test "continues processing after broadcast failure" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: FailingDispatcher)

      {:ok, state} = PubSubSink.write_event(run_started(), [], state)
      {:ok, state} = PubSubSink.write_event(message_streamed("hi"), [], state)

      assert state.error_count == 2
      assert state.broadcast_count == 0
    end
  end

  describe "flush/1" do
    test "returns ok with unchanged state" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      assert {:ok, ^state} = PubSubSink.flush(state)
    end
  end

  describe "close/1" do
    test "returns ok" do
      {:ok, state} =
        PubSubSink.init(pubsub: self(), topic: "t", dispatcher: MockDispatcher)

      assert :ok = PubSubSink.close(state)
    end
  end

  describe "integration: full event sequence" do
    test "broadcasts each event in a session event sequence" do
      {:ok, state} =
        PubSubSink.init(
          pubsub: self(),
          topic: "test:stream",
          dispatcher: MockDispatcher
        )

      events = simple_session_events()

      final_state =
        Enum.reduce(events, state, fn event, acc ->
          {:ok, new_acc} = PubSubSink.write_event(event, [], acc)
          new_acc
        end)

      assert final_state.broadcast_count == length(events)
      assert final_state.error_count == 0

      for _event <- events do
        assert_received {:broadcast, "test:stream", {:asm_event, _, _}}
      end
    end
  end
end
