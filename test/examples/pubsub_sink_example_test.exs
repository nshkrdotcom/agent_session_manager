defmodule AgentSessionManager.Examples.PubSubSinkExampleTest do
  use ExUnit.Case, async: true

  setup_all do
    unless Code.ensure_loaded?(PubSubSinkExample) do
      {_, _binding} =
        Code.eval_string(
          File.read!("examples/pubsub_sink.exs")
          |> String.replace(~r/^PubSubSinkExample\.main\(System\.argv\(\)\)$/m, ":ok"),
          [],
          file: "examples/pubsub_sink.exs"
        )
    end

    :ok
  end

  test "starts pubsub and can broadcast/subscribe" do
    old_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, old_trap_exit) end)

    pubsub_name = :"asm_pubsub_example_test_#{System.unique_integer([:positive, :monotonic])}"
    topic = "asm:test-topic"

    assert {:ok, pubsub_sup} = PubSubSinkExample.start_pubsub(pubsub_name)
    assert Process.alive?(pubsub_sup)

    assert :ok = Phoenix.PubSub.subscribe(pubsub_name, topic)
    assert :ok = Phoenix.PubSub.broadcast(pubsub_name, topic, :ping)
    assert_receive :ping

    GenServer.stop(pubsub_sup, :normal)
  end

  test "uses explicit static topics for sink and callback paths" do
    content = File.read!("examples/pubsub_sink.exs")

    assert content =~ "topic: path1_topic()"
    assert content =~ "event_callback(__MODULE__.PubSub, topic: path2_topic())"
  end
end
