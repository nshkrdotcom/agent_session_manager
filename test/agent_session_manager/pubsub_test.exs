defmodule AgentSessionManager.PubSubTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.PubSub, as: ASMPubSub
  alias AgentSessionManager.PubSub.Topic

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    # Start a real PubSub for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    %{pubsub: pubsub_name}
  end

  describe "event_callback/2" do
    test "returns a 1-arity function", %{pubsub: pubsub} do
      callback = ASMPubSub.event_callback(pubsub)
      assert is_function(callback, 1)
    end

    test "broadcasts event to session-scoped topic", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"
      topic = Topic.build_session_topic("asm", session_id)
      Phoenix.PubSub.subscribe(pubsub, topic)

      callback = ASMPubSub.event_callback(pubsub)

      event = %{
        type: :run_started,
        session_id: session_id,
        run_id: "run_001",
        data: %{},
        provider: :claude
      }

      callback.(event)

      assert_receive {:asm_event, ^session_id, ^event}
    end

    test "broadcasts to run-scoped topic when scope: :run", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"
      run_id = "run_test_#{System.unique_integer([:positive])}"
      topic = Topic.build_run_topic("asm", session_id, run_id)
      Phoenix.PubSub.subscribe(pubsub, topic)

      callback = ASMPubSub.event_callback(pubsub, scope: :run)

      event = %{
        type: :run_started,
        session_id: session_id,
        run_id: run_id,
        data: %{},
        provider: :claude
      }

      callback.(event)

      assert_receive {:asm_event, ^session_id, ^event}
    end

    test "broadcasts to type-scoped topic when scope: :type", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"
      topic = Topic.build_type_topic("asm", session_id, :run_started)
      Phoenix.PubSub.subscribe(pubsub, topic)

      callback = ASMPubSub.event_callback(pubsub, scope: :type)

      event = %{
        type: :run_started,
        session_id: session_id,
        run_id: "run_001",
        data: %{},
        provider: :claude
      }

      callback.(event)

      assert_receive {:asm_event, ^session_id, ^event}
    end

    test "broadcasts to static topic when :topic is set", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "custom:topic")

      callback = ASMPubSub.event_callback(pubsub, topic: "custom:topic")

      event = %{
        type: :run_started,
        session_id: "ses_123",
        run_id: "run_001",
        data: %{},
        provider: :claude
      }

      callback.(event)

      assert_receive {:asm_event, "ses_123", ^event}
    end

    test "uses custom message_wrapper", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"
      topic = Topic.build_session_topic("asm", session_id)
      Phoenix.PubSub.subscribe(pubsub, topic)

      callback = ASMPubSub.event_callback(pubsub, message_wrapper: :agent_event)

      event = %{
        type: :run_started,
        session_id: session_id,
        run_id: "run_001",
        data: %{},
        provider: :claude
      }

      callback.(event)

      assert_receive {:agent_event, ^session_id, ^event}
    end

    test "uses custom prefix", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"
      topic = Topic.build_session_topic("myapp", session_id)
      Phoenix.PubSub.subscribe(pubsub, topic)

      callback = ASMPubSub.event_callback(pubsub, prefix: "myapp")

      event = %{
        type: :run_started,
        session_id: session_id,
        run_id: "run_001",
        data: %{},
        provider: :claude
      }

      callback.(event)

      assert_receive {:asm_event, ^session_id, ^event}
    end

    test "raises on invalid scope", %{pubsub: pubsub} do
      assert_raise ArgumentError, ~r/invalid :scope/, fn ->
        ASMPubSub.event_callback(pubsub, scope: :invalid)
      end
    end
  end

  describe "subscribe/2" do
    test "subscribes to session topic", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"

      assert :ok = ASMPubSub.subscribe(pubsub, session_id: session_id)

      topic = Topic.build_session_topic("asm", session_id)
      Phoenix.PubSub.broadcast(pubsub, topic, {:asm_event, session_id, %{type: :test}})

      assert_receive {:asm_event, ^session_id, %{type: :test}}
    end

    test "subscribes to run topic", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"
      run_id = "run_test_#{System.unique_integer([:positive])}"

      assert :ok = ASMPubSub.subscribe(pubsub, session_id: session_id, run_id: run_id)

      topic = Topic.build_run_topic("asm", session_id, run_id)
      Phoenix.PubSub.broadcast(pubsub, topic, {:asm_event, session_id, %{type: :test}})

      assert_receive {:asm_event, ^session_id, %{type: :test}}
    end

    test "subscribes to explicit topic", %{pubsub: pubsub} do
      assert :ok = ASMPubSub.subscribe(pubsub, topic: "custom:explicit")

      Phoenix.PubSub.broadcast(pubsub, "custom:explicit", :hello)

      assert_receive :hello
    end

    test "uses custom prefix", %{pubsub: pubsub} do
      session_id = "ses_test_#{System.unique_integer([:positive])}"

      assert :ok = ASMPubSub.subscribe(pubsub, session_id: session_id, prefix: "myapp")

      topic = Topic.build_session_topic("myapp", session_id)
      Phoenix.PubSub.broadcast(pubsub, topic, {:test_msg})

      assert_receive {:test_msg}
    end
  end
end
