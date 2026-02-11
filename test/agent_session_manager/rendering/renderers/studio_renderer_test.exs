defmodule AgentSessionManager.Rendering.Renderers.StudioRendererTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Renderers.StudioRenderer
  import AgentSessionManager.Test.RenderingHelpers

  defp render_events(events, opts) do
    {:ok, state} = StudioRenderer.init(opts)

    {fragments, final_state} =
      Enum.reduce(events, {[], state}, fn event, {acc, state} ->
        {:ok, iodata, new_state} = StudioRenderer.render_event(event, state)
        {acc ++ [iodata], new_state}
      end)

    {:ok, finish_iodata, final_state} = StudioRenderer.finish(final_state)
    {fragments ++ [finish_iodata], final_state}
  end

  defp render_single(event, opts) do
    {:ok, state} = StudioRenderer.init(opts)
    {:ok, iodata, state} = StudioRenderer.render_event(event, state)
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
      assert {:ok, state} = StudioRenderer.init([])
      assert state.color == true
      assert state.tool_output == :summary
      assert state.show_spinner == true
      assert state.indent == 2
    end

    test "accepts custom options" do
      assert {:ok, state} = StudioRenderer.init(color: false, tool_output: :preview)
      assert state.color == false
      assert state.tool_output == :preview
    end
  end

  describe "run_started" do
    test "emits session started line with model" do
      {text, _state} = render_single(run_started(model: "claude-sonnet-4-5"), tty: true)
      plain = strip_ansi(text)
      assert plain =~ "●"
      assert plain =~ "session started"
      assert plain =~ "claude-sonnet-4-5"
    end
  end

  describe "message_streamed" do
    test "renders a single chunk with indentation" do
      {text, _state} = render_single(message_streamed("Hello"), tty: true)
      plain = strip_ansi(text)
      assert plain =~ "\n  Hello"
    end

    test "concatenates multiple chunks without duplicate prefix" do
      {:ok, state} = StudioRenderer.init(tty: true)
      {:ok, io1, state} = StudioRenderer.render_event(message_streamed("Hello"), state)
      {:ok, io2, _state} = StudioRenderer.render_event(message_streamed(" world"), state)

      text1 = strip_ansi(IO.iodata_to_binary(io1))
      text2 = strip_ansi(IO.iodata_to_binary(io2))

      assert text1 =~ "\n  Hello"
      assert text2 == " world"
    end

    test "adds block separation when transitioning to tool events" do
      events = [
        message_streamed("Thinking..."),
        tool_call_started("Read", input: %{"file_path" => "lib/sink.ex"})
      ]

      {fragments, _state} = render_events(events, tty: true)
      text = combined_text(fragments)

      assert text =~ "\n  Thinking...\n"
      assert text =~ "◐ Reading lib/sink.ex"
    end
  end

  describe "tool_call_started" do
    test "closes text block before tool status and omits trailing newline in tty mode" do
      {:ok, state} = StudioRenderer.init(tty: true)
      {:ok, _, state} = StudioRenderer.render_event(message_streamed("Working..."), state)
      {:ok, iodata, _state} = StudioRenderer.render_event(tool_call_started("Read"), state)

      text = strip_ansi(IO.iodata_to_binary(iodata))

      assert String.starts_with?(text, "\n")
      assert text =~ "◐"
      assert text =~ "Reading"
      refute String.ends_with?(text, "\n")
    end
  end

  describe "tool_call_completed" do
    test "overwrites status line and prints success summary in tty mode" do
      {:ok, state} = StudioRenderer.init(tty: true)

      {:ok, _, state} =
        StudioRenderer.render_event(
          tool_call_started("bash", input: %{"command" => "mix test"}),
          state
        )

      event =
        tool_call_completed("bash",
          input: %{"command" => "mix test"},
          output: String.duplicate("a", 156)
        )

      {:ok, iodata, _state} = StudioRenderer.render_event(event, state)
      text = strip_ansi(IO.iodata_to_binary(iodata))

      assert String.starts_with?(text, "\r\e[2K")
      assert text =~ "✓"
      assert text =~ "Ran: mix test (exit 0, 156 chars)"
      assert String.ends_with?(text, "\n")
    end

    test "shows failure icon for failed tools" do
      {:ok, state} = StudioRenderer.init(tty: true)

      {:ok, _, state} =
        StudioRenderer.render_event(
          tool_call_started("bash", input: %{"command" => "mix compile"}),
          state
        )

      failed_event =
        event(:tool_call_completed, %{
          tool_name: "bash",
          tool_call_id: "tool_bash_001",
          tool_input: %{"command" => "mix compile"},
          tool_output: "error",
          exit_code: 1,
          status: "failed"
        })

      {:ok, iodata, _state} = StudioRenderer.render_event(failed_event, state)
      text = strip_ansi(IO.iodata_to_binary(iodata))

      assert text =~ "✗"
      assert text =~ "Bash failed: mix compile"
    end
  end

  describe "tool_call_completed with :preview mode" do
    test "renders summary and preview lines with │ prefix" do
      {:ok, state} = StudioRenderer.init(tty: true, tool_output: :preview)

      {:ok, _, state} =
        StudioRenderer.render_event(
          tool_call_started("bash", input: %{"command" => "mix test"}),
          state
        )

      event =
        tool_call_completed("bash",
          input: %{"command" => "mix test"},
          output: "line1\nline2\nline3\nline4\n"
        )

      {:ok, iodata, _state} = StudioRenderer.render_event(event, state)
      text = strip_ansi(IO.iodata_to_binary(iodata))

      assert text =~ "Ran: mix test"
      assert text =~ "│ line2"
      assert text =~ "│ line3"
      assert text =~ "│ line4"
    end
  end

  describe "tool_call_completed with :full mode" do
    test "renders summary and full output lines with ┊ prefix" do
      {:ok, state} = StudioRenderer.init(tty: true, tool_output: :full)

      {:ok, _, state} =
        StudioRenderer.render_event(
          tool_call_started("bash", input: %{"command" => "mix test"}),
          state
        )

      event =
        tool_call_completed("bash",
          input: %{"command" => "mix test"},
          output: "line1\nline2\n"
        )

      {:ok, iodata, _state} = StudioRenderer.render_event(event, state)
      text = strip_ansi(IO.iodata_to_binary(iodata))

      assert text =~ "Ran: mix test"
      assert text =~ "┊ line1"
      assert text =~ "┊ line2"
    end
  end

  describe "token_usage_updated" do
    test "is silent and accumulates tokens in state" do
      {text, state} = render_single(token_usage_updated(847, 312), tty: true)
      assert text == ""
      assert state.total_input_tokens == 847
      assert state.total_output_tokens == 312
    end
  end

  describe "message_received" do
    test "is silent" do
      {text, _state} = render_single(message_received("Hello"), tty: true)
      assert text == ""
    end
  end

  describe "run_completed" do
    test "emits completion summary with stop reason, token counts, and tool count" do
      events = [
        run_started(),
        token_usage_updated(847, 312),
        tool_call_started("Read", input: %{"file_path" => "lib/sink.ex"}),
        tool_call_completed("Read", input: %{"file_path" => "lib/sink.ex"}, output: "x"),
        run_completed(stop_reason: "end_turn")
      ]

      {fragments, _state} = render_events(events, tty: true)
      text = combined_text(fragments)

      assert text =~ "●"
      assert text =~ "Session complete (end_turn)"
      assert text =~ "847/312 tokens, 1 tools"
    end
  end

  describe "run_failed" do
    test "emits failure line with error message" do
      {text, _state} = render_single(run_failed("connection lost"), tty: true)
      plain = strip_ansi(text)
      assert plain =~ "✗"
      assert plain =~ "connection lost"
    end
  end

  describe "finish/1" do
    test "returns empty iodata" do
      {:ok, state} = StudioRenderer.init([])
      {:ok, iodata, _state} = StudioRenderer.finish(state)
      assert IO.iodata_length(iodata) == 0
    end
  end

  describe "phase transitions (integration)" do
    test "renders simple session events cleanly" do
      {fragments, _state} = render_events(simple_session_events(), tty: false)
      text = combined_text(fragments)

      assert text =~ "session started"
      assert text =~ "\n  Hello"
      assert text =~ "Session complete"
    end

    test "renders tool use session with formatted tool blocks" do
      {fragments, _state} = render_events(tool_use_session_events(), tty: false)
      text = combined_text(fragments)

      assert text =~ "◐"
      assert text =~ "Read"
      assert text =~ "✓"
      assert text =~ "Session complete"
    end

    test "ensures text -> tool -> text transitions have blank-line separation" do
      events = [
        message_streamed("First block"),
        tool_call_started("Read", input: %{"file_path" => "lib/sink.ex"}),
        tool_call_completed("Read", input: %{"file_path" => "lib/sink.ex"}, output: "ok"),
        message_streamed("Second block")
      ]

      {fragments, _state} = render_events(events, tty: false)
      text = combined_text(fragments)

      assert text =~ "First block\n"
      assert text =~ "✓ Read lib/sink.ex"
      assert text =~ "\n\n  Second block"
    end
  end

  describe "non-TTY mode" do
    test "prints tool started and completed lines without overwriting" do
      {:ok, state} = StudioRenderer.init(tty: false)

      {:ok, started, state} =
        StudioRenderer.render_event(
          tool_call_started("Read", input: %{"file_path" => "lib/sink.ex"}),
          state
        )

      {:ok, completed, _state} =
        StudioRenderer.render_event(
          tool_call_completed("Read", input: %{"file_path" => "lib/sink.ex"}, output: "line"),
          state
        )

      started_text = strip_ansi(IO.iodata_to_binary(started))
      completed_text = strip_ansi(IO.iodata_to_binary(completed))

      assert String.ends_with?(started_text, "\n")
      refute completed_text =~ "\r\e[2K"
      assert started_text =~ "◐ Reading lib/sink.ex"
      assert completed_text =~ "✓ Read lib/sink.ex"
    end
  end

  describe "color disabled" do
    test "does not emit ANSI color codes" do
      {text, _state} = render_single(run_started(), color: false, tty: false)
      assert strip_ansi(text) == text
    end
  end
end
