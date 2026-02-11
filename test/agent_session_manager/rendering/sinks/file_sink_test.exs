defmodule AgentSessionManager.Rendering.Sinks.FileSinkTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Sinks.FileSink

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{path: Path.join(dir, "test_output.log")}
  end

  describe "init/1" do
    test "initializes and creates file", %{path: path} do
      assert {:ok, state} = FileSink.init(path: path)
      assert state.path == path
      assert state.io != nil
      FileSink.close(state)
    end

    test "returns error when no path or io provided" do
      assert {:error, _reason} = FileSink.init([])
    end

    test "accepts pre-opened :io device", %{path: path} do
      {:ok, io} = File.open(path, [:write, :utf8])
      assert {:ok, state} = FileSink.init(io: io)
      assert state.io == io
      assert state.owns_io == false
      File.close(io)
    end
  end

  describe "write/2" do
    test "writes text to file with ANSI stripped", %{path: path} do
      {:ok, state} = FileSink.init(path: path)

      {:ok, state} = FileSink.write("\e[0;34mHello\e[0m world\n", state)
      FileSink.flush(state)
      FileSink.close(state)

      content = File.read!(path)
      assert content == "Hello world\n"
      refute content =~ "\e["
    end

    test "writes multiple fragments", %{path: path} do
      {:ok, state} = FileSink.init(path: path)

      {:ok, state} = FileSink.write("Hello", state)
      {:ok, state} = FileSink.write(" world", state)
      FileSink.flush(state)
      FileSink.close(state)

      content = File.read!(path)
      assert content == "Hello world"
    end

    test "strips cursor control escape sequences", %{path: path} do
      {:ok, state} = FileSink.init(path: path)

      {:ok, state} = FileSink.write("line one\r\e[2Kline two\n", state)
      FileSink.flush(state)
      FileSink.close(state)

      content = File.read!(path)
      assert content == "line oneline two\n"
      refute content =~ "\r"
      refute content =~ "\e[2K"
    end
  end

  describe "write_event/3" do
    test "writes rendered iodata with ANSI stripped", %{path: path} do
      {:ok, state} = FileSink.init(path: path)
      event = %{type: :run_started, data: %{}}

      {:ok, state} = FileSink.write_event(event, "\e[1;31mERROR\e[0m\n", state)
      FileSink.flush(state)
      FileSink.close(state)

      content = File.read!(path)
      assert content == "ERROR\n"
    end
  end

  describe "flush/1" do
    test "flushes data to disk", %{path: path} do
      {:ok, state} = FileSink.init(path: path)
      {:ok, state} = FileSink.write("test data", state)
      {:ok, _state} = FileSink.flush(state)

      content = File.read!(path)
      assert content == "test data"
      FileSink.close(state)
    end
  end

  describe "close/1" do
    test "closes the file handle when owns_io", %{path: path} do
      {:ok, state} = FileSink.init(path: path)
      {:ok, state} = FileSink.write("data", state)
      assert :ok = FileSink.close(state)
    end

    test "does not close when not owns_io", %{path: path} do
      {:ok, io} = File.open(path, [:write, :utf8])
      {:ok, state} = FileSink.init(io: io)
      {:ok, state} = FileSink.write("data", state)
      assert :ok = FileSink.close(state)
      # IO device should still be usable
      assert :ok = IO.binwrite(io, "more data")
      File.close(io)
    end
  end

  describe "io option" do
    test "writes to pre-opened io device with ANSI stripped", %{path: path} do
      {:ok, io} = File.open(path, [:write, :utf8])
      {:ok, state} = FileSink.init(io: io)

      {:ok, state} = FileSink.write("\e[0;34mHello\e[0m world\n", state)
      FileSink.flush(state)
      FileSink.close(state)
      File.close(io)

      content = File.read!(path)
      assert content == "Hello world\n"
    end

    test "preserves pre-written content when io is pre-opened", %{path: path} do
      {:ok, io} = File.open(path, [:write, :utf8])
      IO.binwrite(io, "HEADER\n")

      {:ok, state} = FileSink.init(io: io)
      {:ok, state} = FileSink.write("body\n", state)
      FileSink.flush(state)
      FileSink.close(state)
      File.close(io)

      content = File.read!(path)
      assert content == "HEADER\nbody\n"
    end
  end
end
