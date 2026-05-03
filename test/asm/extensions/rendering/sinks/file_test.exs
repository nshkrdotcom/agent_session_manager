defmodule ASM.Extensions.Rendering.Sinks.FileTest do
  use ASM.TestCase, async: true

  alias ASM.Extensions.Rendering.Sinks.File, as: FileSink

  test "write/2 strips ANSI CSI sequences and standalone carriage returns" do
    {:ok, io} = StringIO.open("")
    {:ok, state} = FileSink.init(io: io, strip_ansi: true)

    assert {:ok, ^state} = FileSink.write(["\e[31mred\e[0m", "\r", "next", "\r\n"], state)
    {_input, output} = StringIO.contents(io)

    assert output == "rednext\r\n"
  end
end
