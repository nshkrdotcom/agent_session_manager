defmodule ASM.Parser.AmpTest do
  use ASM.TestCase

  alias ASM.Message
  alias ASM.Parser.Amp

  test "parses streamed delta payload" do
    raw = %{"type" => "message_streamed", "delta" => "amp chunk"}

    assert {:ok, {:assistant_delta, %Message.Partial{} = payload}} = Amp.parse(raw)
    assert payload.delta == "amp chunk"
    assert payload.content_type == :text
  end

  test "parses tool call started payload" do
    raw = %{
      "type" => "tool_call_started",
      "tool_call_id" => "tool-1",
      "tool_name" => "bash",
      "tool_input" => %{"command" => "ls -la"}
    }

    assert {:ok, {:tool_use, %Message.ToolUse{} = payload}} = Amp.parse(raw)
    assert payload.tool_name == "bash"
    assert payload.tool_id == "tool-1"
    assert payload.input["command"] == "ls -la"
  end

  test "parses successful tool result payload" do
    raw = %{
      "type" => "tool_call_completed",
      "tool_call_id" => "tool-1",
      "tool_output" => %{"ok" => true}
    }

    assert {:ok, {:tool_result, %Message.ToolResult{} = payload}} = Amp.parse(raw)
    assert payload.tool_id == "tool-1"
    assert payload.content == %{"ok" => true}
    refute payload.is_error
  end

  test "parses failed tool result payload" do
    raw = %{
      "type" => "tool_call_failed",
      "tool_call_id" => "tool-1",
      "tool_output" => "denied"
    }

    assert {:ok, {:tool_result, %Message.ToolResult{} = payload}} = Amp.parse(raw)
    assert payload.tool_id == "tool-1"
    assert payload.content == "denied"
    assert payload.is_error
  end

  test "parses run completed payload into result" do
    raw = %{
      "type" => "run_completed",
      "stop_reason" => "end_turn",
      "duration_ms" => 120,
      "token_usage" => %{"input_tokens" => 7, "output_tokens" => 9}
    }

    assert {:ok, {:result, %Message.Result{} = payload}} = Amp.parse(raw)
    assert payload.stop_reason == "end_turn"
    assert payload.duration_ms == 120
    assert payload.usage.input_tokens == 7
    assert payload.usage.output_tokens == 9
  end

  test "parses provider error payload" do
    raw = %{
      "type" => "error_occurred",
      "error_message" => "rate limit",
      "error_code" => "rate_limit"
    }

    assert {:ok, {:error, %Message.Error{} = payload}} = Amp.parse(raw)
    assert payload.message == "rate limit"
    assert payload.kind == :rate_limit
    assert payload.severity == :error
  end

  test "unknown event types fallback to raw payload" do
    assert {:ok, {:raw, %Message.Raw{} = raw}} = Amp.parse(%{"type" => "odd_event", "x" => 1})

    assert raw.provider == :amp
    assert raw.type == "odd_event"
    assert raw.data["x"] == 1
  end

  test "non-map input returns parse error" do
    assert {:error, error} = Amp.parse("bad")
    assert error.kind == :parse_error
    assert error.domain == :parser
  end
end
