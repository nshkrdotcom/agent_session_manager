defmodule ASM.Extensions.Rendering.Sinks.TTYTest do
  use ASM.TestCase

  alias ASM.Extensions.Rendering.Sinks.TTY
  alias ASM.Test.RenderingHelpers

  test "write/2 writes rendered output to configured device" do
    {:ok, io_device} = StringIO.open("")
    assert {:ok, state} = TTY.init(device: io_device)

    assert {:ok, state} = TTY.write("hello", state)
    assert {:ok, _state} = TTY.write(" world", state)

    {_input, output} = StringIO.contents(io_device)
    assert output == "hello world"
  end

  test "write_event/3 forwards rendered iodata for each event" do
    {:ok, io_device} = StringIO.open("")
    assert {:ok, state} = TTY.init(device: io_device)

    assert {:ok, _state} = TTY.write_event(RenderingHelpers.run_started(), "r+", state)

    {_input, output} = StringIO.contents(io_device)
    assert output == "r+"
  end

  test "flush/1 and close/1 are safe no-ops" do
    assert {:ok, state} = TTY.init([])
    assert {:ok, _state} = TTY.flush(state)
    assert :ok = TTY.close(state)
  end
end
