defmodule AgentSessionManager.Rendering.Renderers.PassthroughRendererTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Renderers.PassthroughRenderer
  import AgentSessionManager.Test.RenderingHelpers

  describe "init/1" do
    test "initializes with default options" do
      assert {:ok, state} = PassthroughRenderer.init([])
      assert is_map(state)
    end
  end

  describe "render_event/2" do
    test "returns empty iodata for all events" do
      {:ok, state} = PassthroughRenderer.init([])

      {:ok, iodata, _state} = PassthroughRenderer.render_event(run_started(), state)
      assert IO.iodata_length(iodata) == 0

      {:ok, iodata, _state} = PassthroughRenderer.render_event(message_streamed("hi"), state)
      assert IO.iodata_length(iodata) == 0

      {:ok, iodata, _state} = PassthroughRenderer.render_event(tool_call_started("Read"), state)
      assert IO.iodata_length(iodata) == 0

      {:ok, iodata, _state} = PassthroughRenderer.render_event(run_completed(), state)
      assert IO.iodata_length(iodata) == 0
    end

    test "preserves state across calls" do
      {:ok, state} = PassthroughRenderer.init([])
      {:ok, _, state} = PassthroughRenderer.render_event(run_started(), state)
      {:ok, _, state} = PassthroughRenderer.render_event(message_streamed("hi"), state)
      {:ok, _, state} = PassthroughRenderer.render_event(run_completed(), state)
      assert is_map(state)
    end
  end

  describe "finish/1" do
    test "returns empty iodata" do
      {:ok, state} = PassthroughRenderer.init([])
      {:ok, iodata, _state} = PassthroughRenderer.finish(state)
      assert IO.iodata_length(iodata) == 0
    end
  end
end
