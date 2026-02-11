defmodule AgentSessionManager.Rendering.Renderers.CompactRendererTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Renderers.CompactRenderer
  import AgentSessionManager.Test.RenderingHelpers

  defp render_events(events, opts \\ []) do
    {:ok, state} = CompactRenderer.init(opts)

    {fragments, final_state} =
      Enum.reduce(events, {[], state}, fn event, {acc, state} ->
        {:ok, iodata, new_state} = CompactRenderer.render_event(event, state)
        {acc ++ [iodata], new_state}
      end)

    {:ok, finish_iodata, final_state} = CompactRenderer.finish(final_state)
    {fragments ++ [finish_iodata], final_state}
  end

  defp render_single(event, opts \\ []) do
    {:ok, state} = CompactRenderer.init(opts)
    {:ok, iodata, state} = CompactRenderer.render_event(event, state)
    {IO.iodata_to_binary(iodata), state}
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\x1b\[[0-9;]*m/, "")
  end

  defp combined_text(fragments) do
    fragments
    |> Enum.map_join(&IO.iodata_to_binary/1)
    |> strip_ansi()
  end

  describe "init/1" do
    test "initializes with default options" do
      assert {:ok, state} = CompactRenderer.init([])
      assert is_map(state)
    end

    test "accepts color: false option" do
      assert {:ok, state} = CompactRenderer.init(color: false)
      assert state.color == false
    end
  end

  describe "run_started" do
    test "emits run start token with model" do
      {text, _state} = render_single(run_started())
      plain = strip_ansi(text)
      assert plain =~ "r+"
      assert plain =~ "sonnet"
    end

    test "emits model abbreviation" do
      event = run_started(model: "claude-opus-4-6-20250801")
      {text, _state} = render_single(event)
      plain = strip_ansi(text)
      assert plain =~ "opus"
    end
  end

  describe "message_streamed" do
    test "emits stream prefix on first chunk" do
      {text, _state} = render_single(message_streamed("Hello"))
      plain = strip_ansi(text)
      assert plain =~ ">>"
      assert plain =~ "Hello"
    end

    test "continues streaming without prefix on subsequent chunks" do
      {:ok, state} = CompactRenderer.init([])
      {:ok, io1, state} = CompactRenderer.render_event(message_streamed("Hello"), state)
      {:ok, io2, _state} = CompactRenderer.render_event(message_streamed(" world"), state)

      text1 = strip_ansi(IO.iodata_to_binary(io1))
      text2 = strip_ansi(IO.iodata_to_binary(io2))

      assert text1 =~ ">>"
      assert text1 =~ "Hello"
      # Subsequent chunk should NOT have >> prefix
      refute text2 =~ ">>"
      assert text2 =~ " world"
    end

    test "ends stream when non-streamed event follows" do
      events = [
        message_streamed("Hello"),
        run_completed()
      ]

      {fragments, _state} = render_events(events)
      text = combined_text(fragments)

      # Should have stream text followed by newline, then the run completed token
      assert text =~ "Hello"
      assert text =~ "r-"
    end
  end

  describe "tool_call_started" do
    test "emits tool start token with name" do
      {text, _state} = render_single(tool_call_started("Read"))
      plain = strip_ansi(text)
      assert plain =~ "t+"
      assert plain =~ "Read"
    end

    test "tracks tool state" do
      {_text, state} = render_single(tool_call_started("Read"))
      assert state.current_tool == "Read"
      assert state.tool_count == 1
    end

    test "does not set current_tool_id from legacy aliases" do
      event = event(:tool_call_started, %{tool_name: "Read", tool_use_id: "legacy_1"})
      {_text, state} = render_single(event)
      assert state.current_tool_id == nil
    end
  end

  describe "tool_call_completed" do
    test "emits tool end token with name" do
      {text, _state} = render_single(tool_call_completed("Read"))
      plain = strip_ansi(text)
      assert plain =~ "t-"
      assert plain =~ "Read"
    end

    test "includes result preview when present" do
      event = tool_call_completed("Read", output: "defmodule Foo do\nend")
      {text, _state} = render_single(event)
      plain = strip_ansi(text)
      assert plain =~ "defmodule Foo"
    end

    test "clears tool state" do
      {:ok, state} = CompactRenderer.init([])
      {:ok, _, state} = CompactRenderer.render_event(tool_call_started("Read"), state)
      assert state.current_tool == "Read"

      {:ok, _, state} = CompactRenderer.render_event(tool_call_completed("Read"), state)
      assert state.current_tool == nil
    end
  end

  describe "token_usage_updated" do
    test "emits usage token" do
      {text, _state} = render_single(token_usage_updated(100, 50))
      plain = strip_ansi(text)
      assert plain =~ "100"
      assert plain =~ "50"
    end
  end

  describe "message_received" do
    test "is rendered (not dropped like prompt_runner)" do
      {text, _state} = render_single(message_received("Hello!"))
      # Should produce some output (even if minimal)
      assert IO.iodata_length(text) > 0
    end
  end

  describe "run_completed" do
    test "emits run end token" do
      {text, _state} = render_single(run_completed())
      plain = strip_ansi(text)
      assert plain =~ "r-"
    end

    test "includes stop reason" do
      event = run_completed(stop_reason: "tool_use")
      {text, _state} = render_single(event)
      plain = strip_ansi(text)
      assert plain =~ "tool"
    end

    test "abbreviates end_turn to end" do
      event = run_completed(stop_reason: "end_turn")
      {text, _state} = render_single(event)
      plain = strip_ansi(text)
      assert plain =~ "end"
    end
  end

  describe "run_failed" do
    test "emits error token" do
      {text, _state} = render_single(run_failed())
      plain = strip_ansi(text)
      assert plain =~ "!"
      assert plain =~ "something went wrong"
    end
  end

  describe "run_cancelled" do
    test "emits cancelled token" do
      {text, _state} = render_single(run_cancelled())
      plain = strip_ansi(text)
      assert plain =~ "!"
      assert plain =~ "cancelled"
    end
  end

  describe "error_occurred" do
    test "emits error token" do
      {text, _state} = render_single(error_occurred("connection lost"))
      plain = strip_ansi(text)
      assert plain =~ "!"
      assert plain =~ "connection lost"
    end
  end

  describe "unknown events" do
    test "emits catch-all token" do
      event = event(:unknown_type, %{foo: "bar"})
      {text, _state} = render_single(event)
      plain = strip_ansi(text)
      assert plain =~ "?"
    end
  end

  describe "full session flow" do
    test "renders a simple session" do
      {fragments, state} = render_events(simple_session_events())
      text = combined_text(fragments)

      assert text =~ "r+"
      assert text =~ "Hello"
      assert text =~ " world"
      assert text =~ "r-"
      assert state.event_count == 6
    end

    test "renders a tool use session" do
      {fragments, state} = render_events(tool_use_session_events())
      text = combined_text(fragments)

      assert text =~ "r+"
      assert text =~ "t+"
      assert text =~ "Read"
      assert text =~ "t-"
      assert text =~ "r-"
      assert state.tool_count == 1
    end
  end

  describe "finish/1" do
    test "emits newline to close any open line" do
      {:ok, state} = CompactRenderer.init([])
      {:ok, _, state} = CompactRenderer.render_event(run_started(), state)
      # State should have line_open = true after emitting a token
      {:ok, iodata, _state} = CompactRenderer.finish(state)
      text = IO.iodata_to_binary(iodata)
      assert text =~ "\n"
    end

    test "emits summary line" do
      {fragments, _state} = render_events(simple_session_events())
      text = combined_text(fragments)
      # Summary should appear at end
      assert text =~ "events"
    end
  end

  describe "color option" do
    test "includes ANSI when color: true (default)" do
      {text, _state} = render_single(run_started())
      binary = IO.iodata_to_binary(text)
      assert binary =~ "\e["
    end

    test "excludes ANSI when color: false" do
      {text, _state} = render_single(run_started(), color: false)
      binary = IO.iodata_to_binary(text)
      refute binary =~ "\e["
    end
  end

  describe "event counting" do
    test "increments event count" do
      events = [run_started(), message_streamed("hi"), run_completed()]
      {_fragments, state} = render_events(events)
      assert state.event_count == 3
    end

    test "increments tool count" do
      events = [
        tool_call_started("Read"),
        tool_call_completed("Read"),
        tool_call_started("Edit"),
        tool_call_completed("Edit")
      ]

      {_fragments, state} = render_events(events)
      assert state.tool_count == 2
    end
  end
end
