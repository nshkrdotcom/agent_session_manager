defmodule ASM.Extensions.Rendering.Sinks.FileTest do
  use ASM.TestCase

  alias ASM.Extensions.Rendering.Sinks.File, as: FileSink
  alias ASM.Test.RenderingHelpers

  test "write/2 persists rendered output with ANSI stripped" do
    path = temp_path("file-sink")
    on_exit(fn -> _ = Elixir.File.rm(path) end)

    assert {:ok, state} = FileSink.init(path: path)
    assert {:ok, state} = FileSink.write("\e[0;32mhello\e[0m", state)
    assert {:ok, state} = FileSink.write(" world\n", state)
    assert {:ok, _state} = FileSink.flush(state)
    assert :ok = FileSink.close(state)

    assert Elixir.File.read!(path) == "hello world\n"
  end

  test "write_event/3 writes rendered iodata" do
    path = temp_path("file-sink-event")
    on_exit(fn -> _ = Elixir.File.rm(path) end)

    assert {:ok, state} = FileSink.init(path: path)
    assert {:ok, state} = FileSink.write_event(RenderingHelpers.run_started(), "r+", state)
    assert {:ok, _state} = FileSink.flush(state)
    assert :ok = FileSink.close(state)

    assert Elixir.File.read!(path) == "r+"
  end

  test "init/1 accepts pre-opened io and does not own it" do
    path = temp_path("file-sink-io")
    on_exit(fn -> _ = Elixir.File.rm(path) end)
    {:ok, io_device} = Elixir.File.open(path, [:write, :utf8])

    assert {:ok, state} = FileSink.init(io: io_device)
    assert state.owns_io == false

    assert {:ok, state} = FileSink.write("line", state)
    assert {:ok, _state} = FileSink.flush(state)
    assert :ok = FileSink.close(state)

    assert :ok = IO.binwrite(io_device, " two")
    assert :ok = Elixir.File.close(io_device)
    assert Elixir.File.read!(path) == "line two"
  end

  defp temp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "asm-rendering-#{prefix}-#{System.unique_integer([:positive])}.log"
    )
  end
end
