defmodule AgentSessionManager.Rendering.Sinks.TTYSinkTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Sinks.TTYSink

  describe "init/1" do
    test "initializes with default options" do
      assert {:ok, state} = TTYSink.init([])
      assert is_map(state)
    end

    test "accepts a custom device" do
      {:ok, io} = StringIO.open("")
      assert {:ok, state} = TTYSink.init(device: io)
      assert state.device == io
    end
  end

  describe "write/2" do
    test "writes iodata to device" do
      {:ok, io} = StringIO.open("")
      {:ok, state} = TTYSink.init(device: io)

      {:ok, _state} = TTYSink.write("Hello world\n", state)

      {_input, output} = StringIO.contents(io)
      assert output == "Hello world\n"
    end

    test "writes multiple fragments" do
      {:ok, io} = StringIO.open("")
      {:ok, state} = TTYSink.init(device: io)

      {:ok, state} = TTYSink.write("Hello", state)
      {:ok, _state} = TTYSink.write(" world", state)

      {_input, output} = StringIO.contents(io)
      assert output == "Hello world"
    end
  end

  describe "write_event/3" do
    test "writes rendered iodata (delegates to write)" do
      {:ok, io} = StringIO.open("")
      {:ok, state} = TTYSink.init(device: io)

      event = %{type: :run_started, data: %{}}
      {:ok, _state} = TTYSink.write_event(event, "rendered text", state)

      {_input, output} = StringIO.contents(io)
      assert output == "rendered text"
    end
  end

  describe "flush/1" do
    test "returns ok" do
      {:ok, state} = TTYSink.init([])
      assert {:ok, _state} = TTYSink.flush(state)
    end
  end

  describe "close/1" do
    test "returns ok" do
      {:ok, state} = TTYSink.init([])
      assert :ok = TTYSink.close(state)
    end
  end
end
