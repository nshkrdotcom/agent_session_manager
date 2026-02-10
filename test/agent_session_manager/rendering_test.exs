defmodule AgentSessionManager.RenderingTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.PassthroughRenderer
  alias AgentSessionManager.Rendering.Sinks.CallbackSink
  import AgentSessionManager.Test.RenderingHelpers

  describe "stream/2" do
    test "processes a simple event stream end-to-end" do
      test_pid = self()
      callback = fn event, _iodata -> send(test_pid, {:event, event.type}) end

      result =
        Rendering.stream(simple_session_events(),
          renderer: {PassthroughRenderer, []},
          sinks: [{CallbackSink, [callback: callback]}]
        )

      assert result == :ok

      assert_received {:event, :run_started}
      assert_received {:event, :message_streamed}
      assert_received {:event, :run_completed}
    end

    test "processes tool use events" do
      test_pid = self()
      callback = fn event, _iodata -> send(test_pid, {:event, event.type}) end

      result =
        Rendering.stream(tool_use_session_events(),
          renderer: {PassthroughRenderer, []},
          sinks: [{CallbackSink, [callback: callback]}]
        )

      assert result == :ok

      assert_received {:event, :tool_call_started}
      assert_received {:event, :tool_call_completed}
    end

    test "forwards rendered iodata to sinks" do
      test_pid = self()
      callback = fn _event, iodata -> send(test_pid, {:rendered, IO.iodata_to_binary(iodata)}) end

      # Use passthrough (empty iodata) to verify empty forwarding
      Rendering.stream([run_started()],
        renderer: {PassthroughRenderer, []},
        sinks: [{CallbackSink, [callback: callback]}]
      )

      assert_received {:rendered, ""}
    end

    test "works with multiple sinks" do
      pid1 = self()
      pid2 = self()
      cb1 = fn event, _iodata -> send(pid1, {:sink1, event.type}) end
      cb2 = fn event, _iodata -> send(pid2, {:sink2, event.type}) end

      Rendering.stream([run_started()],
        renderer: {PassthroughRenderer, []},
        sinks: [
          {CallbackSink, [callback: cb1]},
          {CallbackSink, [callback: cb2]}
        ]
      )

      assert_received {:sink1, :run_started}
      assert_received {:sink2, :run_started}
    end

    test "handles empty event stream" do
      callback = fn _event, _iodata -> :ok end

      result =
        Rendering.stream([],
          renderer: {PassthroughRenderer, []},
          sinks: [{CallbackSink, [callback: callback]}]
        )

      assert result == :ok
    end

    test "returns error when sink init fails" do
      result =
        Rendering.stream([run_started()],
          renderer: {PassthroughRenderer, []},
          sinks: [{CallbackSink, []}]
        )

      assert {:error, _reason} = result
    end

    test "processes all event types" do
      test_pid = self()
      callback = fn event, _iodata -> send(test_pid, {:type, event.type}) end

      events = [
        run_started(),
        message_streamed("hello"),
        tool_call_started("Read"),
        tool_call_completed("Read", output: "content"),
        token_usage_updated(100, 50),
        message_received("hello"),
        run_completed(),
        run_failed(),
        run_cancelled(),
        error_occurred()
      ]

      Rendering.stream(events,
        renderer: {PassthroughRenderer, []},
        sinks: [{CallbackSink, [callback: callback]}]
      )

      assert_received {:type, :run_started}
      assert_received {:type, :message_streamed}
      assert_received {:type, :tool_call_started}
      assert_received {:type, :tool_call_completed}
      assert_received {:type, :token_usage_updated}
      assert_received {:type, :message_received}
      assert_received {:type, :run_completed}
      assert_received {:type, :run_failed}
      assert_received {:type, :run_cancelled}
      assert_received {:type, :error_occurred}
    end
  end
end
