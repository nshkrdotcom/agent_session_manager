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

    test "returns error when no path provided" do
      assert {:error, _reason} = FileSink.init([])
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
    test "closes the file handle", %{path: path} do
      {:ok, state} = FileSink.init(path: path)
      {:ok, state} = FileSink.write("data", state)
      assert :ok = FileSink.close(state)
    end
  end
end
