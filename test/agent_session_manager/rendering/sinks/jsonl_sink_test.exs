defmodule AgentSessionManager.Rendering.Sinks.JSONLSinkTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Sinks.JSONLSink
  alias AgentSessionManager.Test.Models, as: TestModels
  import AgentSessionManager.Test.RenderingHelpers

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{path: Path.join(dir, "events.jsonl")}
  end

  describe "init/1" do
    test "initializes and creates file", %{path: path} do
      assert {:ok, state} = JSONLSink.init(path: path)
      assert state.path == path
      JSONLSink.close(state)
    end

    test "returns error when no path provided" do
      assert {:error, _reason} = JSONLSink.init([])
    end

    test "accepts mode option", %{path: path} do
      assert {:ok, state} = JSONLSink.init(path: path, mode: :compact)
      assert state.mode == :compact
      JSONLSink.close(state)
    end
  end

  describe "write/2 (no-op)" do
    test "does nothing for plain text writes", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path)
      {:ok, _state} = JSONLSink.write("some text", state)
      JSONLSink.flush(state)
      JSONLSink.close(state)

      content = File.read!(path)
      assert content == ""
    end
  end

  describe "write_event/3 with :full mode" do
    test "writes event as JSON line", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path, mode: :full)

      event = run_started()
      {:ok, state} = JSONLSink.write_event(event, "", state)
      JSONLSink.flush(state)
      JSONLSink.close(state)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 1

      decoded = Jason.decode!(hd(lines))
      assert decoded["type"] == "run_started"
      assert is_binary(decoded["ts"])
    end

    test "writes multiple events as separate lines", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path, mode: :full)

      {:ok, state} = JSONLSink.write_event(run_started(), "", state)
      {:ok, state} = JSONLSink.write_event(message_streamed("hi"), "", state)
      {:ok, state} = JSONLSink.write_event(run_completed(), "", state)
      JSONLSink.flush(state)
      JSONLSink.close(state)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 3

      types =
        Enum.map(lines, fn line ->
          Jason.decode!(line)["type"]
        end)

      assert types == ["run_started", "message_streamed", "run_completed"]
    end
  end

  describe "write_event/3 with :compact mode" do
    test "writes abbreviated event", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path, mode: :compact)

      event = run_started(model: TestModels.claude_sonnet_model())
      {:ok, state} = JSONLSink.write_event(event, "", state)
      JSONLSink.flush(state)
      JSONLSink.close(state)

      content = File.read!(path)
      decoded = Jason.decode!(hd(String.split(content, "\n", trim: true)))

      assert is_integer(decoded["t"])
      assert is_map(decoded["e"])
      assert decoded["e"]["t"] == "rs"
    end

    test "abbreviates tool events", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path, mode: :compact)

      {:ok, state} = JSONLSink.write_event(tool_call_started("Read"), "", state)

      {:ok, state} =
        JSONLSink.write_event(tool_call_completed("Read", output: "content"), "", state)

      JSONLSink.flush(state)
      JSONLSink.close(state)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      events = Enum.map(lines, &Jason.decode!/1)

      assert Enum.at(events, 0)["e"]["t"] == "ts"
      assert Enum.at(events, 0)["e"]["n"] == "Read"
      assert Enum.at(events, 1)["e"]["t"] == "tc"
    end
  end

  describe "flush/1" do
    test "flushes to disk", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path)
      {:ok, state} = JSONLSink.write_event(run_started(), "", state)
      {:ok, _state} = JSONLSink.flush(state)

      assert File.read!(path) =~ "run_started"
      JSONLSink.close(state)
    end
  end

  describe "close/1" do
    test "closes file handle", %{path: path} do
      {:ok, state} = JSONLSink.init(path: path)
      assert :ok = JSONLSink.close(state)
    end
  end
end
