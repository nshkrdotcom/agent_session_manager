defmodule AgentSessionManager.Rendering.Renderers.VerboseRendererTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Renderers.VerboseRenderer
  alias AgentSessionManager.Test.Models, as: TestModels
  import AgentSessionManager.Test.RenderingHelpers

  defp render_events(events, opts \\ []) do
    {:ok, state} = VerboseRenderer.init(opts)

    {fragments, final_state} =
      Enum.reduce(events, {[], state}, fn event, {acc, state} ->
        {:ok, iodata, new_state} = VerboseRenderer.render_event(event, state)
        {acc ++ [iodata], new_state}
      end)

    {:ok, finish_iodata, final_state} = VerboseRenderer.finish(final_state)
    {fragments ++ [finish_iodata], final_state}
  end

  defp render_single(event, opts \\ []) do
    {:ok, state} = VerboseRenderer.init(opts)
    {:ok, iodata, state} = VerboseRenderer.render_event(event, state)
    {IO.iodata_to_binary(iodata), state}
  end

  defp combined_text(fragments) do
    Enum.map_join(fragments, &IO.iodata_to_binary/1)
  end

  describe "init/1" do
    test "initializes with defaults" do
      assert {:ok, state} = VerboseRenderer.init([])
      assert is_map(state)
    end
  end

  describe "run_started" do
    test "emits bracketed line with model" do
      {text, _state} = render_single(run_started())
      assert text =~ "[run_started]"
      assert text =~ TestModels.claude_sonnet_model()
    end

    test "includes session_id when present" do
      {text, _state} = render_single(run_started())
      assert text =~ "ses_test_123"
    end
  end

  describe "message_streamed" do
    test "emits raw text inline" do
      {text, _state} = render_single(message_streamed("Hello"))
      assert text == "Hello"
    end

    test "subsequent chunks concatenate" do
      {:ok, state} = VerboseRenderer.init([])
      {:ok, io1, state} = VerboseRenderer.render_event(message_streamed("Hello"), state)
      {:ok, io2, _state} = VerboseRenderer.render_event(message_streamed(" world"), state)

      assert IO.iodata_to_binary(io1) == "Hello"
      assert IO.iodata_to_binary(io2) == " world"
    end

    test "inserts line break before next structured event" do
      events = [
        message_streamed("Hello"),
        run_completed()
      ]

      {fragments, _state} = render_events(events)
      text = combined_text(fragments)
      assert text =~ "Hello\n"
      assert text =~ "[run_completed]"
    end
  end

  describe "tool_call_started" do
    test "emits bracketed line with name and id" do
      event = tool_call_started("Read", id: "tu_001", input: %{"path" => "/foo/bar.ex"})
      {text, _state} = render_single(event)
      assert text =~ "[tool_call_started]"
      assert text =~ "Read"
      assert text =~ "tu_001"
    end

    test "includes tool input when present" do
      event = tool_call_started("Read", input: %{"path" => "/foo/bar.ex"})
      {text, _state} = render_single(event)
      assert text =~ "/foo/bar.ex"
    end

    test "ignores legacy tool id aliases" do
      event = event(:tool_call_started, %{tool_name: "Read", tool_use_id: "legacy_1"})
      {text, _state} = render_single(event)
      refute text =~ "legacy_1"
    end
  end

  describe "tool_call_completed" do
    test "emits bracketed line with name" do
      event = tool_call_completed("Read", output: "file contents here")
      {text, _state} = render_single(event)
      assert text =~ "[tool_call_completed]"
      assert text =~ "Read"
    end

    test "includes output preview" do
      event = tool_call_completed("Read", output: "defmodule Foo do\nend")
      {text, _state} = render_single(event)
      assert text =~ "defmodule Foo"
    end

    test "handles nil output" do
      event = tool_call_completed("Read", output: nil)
      # Should not crash
      {text, _state} = render_single(event)
      assert text =~ "[tool_call_completed]"
    end
  end

  describe "token_usage_updated" do
    test "emits usage line" do
      {text, _state} = render_single(token_usage_updated(100, 50))
      assert text =~ "[token_usage]"
      assert text =~ "100"
      assert text =~ "50"
    end

    test "includes cost when cost_usd is present" do
      event =
        event(:token_usage_updated, %{input_tokens: 100, output_tokens: 50, cost_usd: 0.012345})

      {text, _state} = render_single(event)

      assert text =~ "cost=$0.012345"
    end
  end

  describe "message_received" do
    test "emits message line with content preview" do
      {text, _state} = render_single(message_received("Hello!"))
      assert text =~ "[message_received]"
      assert text =~ "Hello!"
    end
  end

  describe "run_completed" do
    test "emits bracketed line with stop reason" do
      {text, _state} = render_single(run_completed())
      assert text =~ "[run_completed]"
      assert text =~ "end_turn"
    end

    test "includes token usage" do
      event = run_completed(token_usage: %{input_tokens: 200, output_tokens: 100})
      {text, _state} = render_single(event)
      assert text =~ "200"
      assert text =~ "100"
    end

    test "includes cost when cost_usd is present" do
      event = event(:run_completed, %{stop_reason: "end_turn", cost_usd: 0.111111})
      {text, _state} = render_single(event)

      assert text =~ "cost=$0.111111"
    end
  end

  describe "run_failed" do
    test "emits error line" do
      {text, _state} = render_single(run_failed())
      assert text =~ "[run_failed]"
      assert text =~ "something went wrong"
    end
  end

  describe "run_cancelled" do
    test "emits cancelled line" do
      {text, _state} = render_single(run_cancelled())
      assert text =~ "[run_cancelled]"
    end
  end

  describe "error_occurred" do
    test "emits error line" do
      {text, _state} = render_single(error_occurred("connection lost"))
      assert text =~ "[error]"
      assert text =~ "connection lost"
    end
  end

  describe "unknown events" do
    test "emits catch-all line" do
      event = event(:unknown_type, %{foo: "bar"})
      {text, _state} = render_single(event)
      assert text =~ "[event]"
      assert text =~ "unknown_type"
    end
  end

  describe "full session flow" do
    test "renders a simple session" do
      {fragments, _state} = render_events(simple_session_events())
      text = combined_text(fragments)

      assert text =~ "[run_started]"
      assert text =~ "Hello"
      assert text =~ " world"
      assert text =~ "[run_completed]"
    end

    test "renders a tool use session" do
      {fragments, _state} = render_events(tool_use_session_events())
      text = combined_text(fragments)

      assert text =~ "[run_started]"
      assert text =~ "[tool_call_started]"
      assert text =~ "Read"
      assert text =~ "[tool_call_completed]"
      assert text =~ "[run_completed]"
    end
  end

  describe "finish/1" do
    test "emits summary" do
      {fragments, _state} = render_events(simple_session_events())
      text = combined_text(fragments)
      assert text =~ "events"
    end
  end
end
