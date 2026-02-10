defmodule AgentSessionManager.Rendering.Sinks.CallbackSinkTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Sinks.CallbackSink
  import AgentSessionManager.Test.RenderingHelpers

  describe "init/1" do
    test "initializes with a callback function" do
      callback = fn _event, _iodata -> :ok end
      assert {:ok, state} = CallbackSink.init(callback: callback)
      assert is_map(state)
    end

    test "returns error when no callback provided" do
      assert {:error, _reason} = CallbackSink.init([])
    end
  end

  describe "write/2" do
    test "does not invoke callback for plain writes" do
      test_pid = self()
      callback = fn _event, _iodata -> send(test_pid, :should_not_receive) end
      {:ok, state} = CallbackSink.init(callback: callback)

      {:ok, _state} = CallbackSink.write("some text", state)
      refute_received :should_not_receive
    end
  end

  describe "write_event/3" do
    test "invokes callback with event and iodata" do
      test_pid = self()
      callback = fn event, iodata -> send(test_pid, {:event, event, iodata}) end
      {:ok, state} = CallbackSink.init(callback: callback)

      event = run_started()
      {:ok, _state} = CallbackSink.write_event(event, "rendered text", state)

      assert_received {:event, ^event, "rendered text"}
    end

    test "invokes callback for each event" do
      test_pid = self()
      callback = fn event, iodata -> send(test_pid, {:event, event.type, iodata}) end
      {:ok, state} = CallbackSink.init(callback: callback)

      events = simple_session_events()

      Enum.reduce(events, state, fn event, acc ->
        {:ok, new_state} = CallbackSink.write_event(event, "", acc)
        new_state
      end)

      assert_received {:event, :run_started, _}
      assert_received {:event, :message_streamed, _}
      assert_received {:event, :run_completed, _}
    end
  end

  describe "flush/1" do
    test "returns ok" do
      callback = fn _event, _iodata -> :ok end
      {:ok, state} = CallbackSink.init(callback: callback)
      assert {:ok, _state} = CallbackSink.flush(state)
    end
  end

  describe "close/1" do
    test "returns ok" do
      callback = fn _event, _iodata -> :ok end
      {:ok, state} = CallbackSink.init(callback: callback)
      assert :ok = CallbackSink.close(state)
    end
  end
end
