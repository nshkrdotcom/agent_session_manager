defmodule ASM.Parser.ClaudeTest do
  use ASM.TestCase

  alias ASM.Message
  alias ASM.Parser.Claude

  test "parses assistant message fixture" do
    raw = fixture("assistant_message.json")
    assert {:ok, {:assistant_message, %Message.Assistant{} = payload}} = Claude.parse(raw)

    assert payload.model == "claude-sonnet-4"
    assert [%ASM.Content.Text{text: "Hello from Claude."}] = payload.content
  end

  test "parses real-world nested assistant message payload" do
    raw = fixture("assistant_message_nested.json")
    assert {:ok, {:assistant_message, %Message.Assistant{} = payload}} = Claude.parse(raw)

    assert payload.model == "claude-opus-4-6"
    assert [%ASM.Content.Text{text: "CLAUDE_OK"}] = payload.content
  end

  test "parses assistant delta fixture" do
    raw = fixture("assistant_delta.json")
    assert {:ok, {:assistant_delta, %Message.Partial{} = payload}} = Claude.parse(raw)
    assert payload.content_type == :text
    assert payload.delta == "streaming chunk"
  end

  test "parses result fixture" do
    raw = fixture("result.json")
    assert {:ok, {:result, %Message.Result{} = payload}} = Claude.parse(raw)
    assert payload.stop_reason == "end_turn"
    assert payload.duration_ms == 42
    assert payload.usage.output_tokens == 5
  end

  test "parses real-world result payload with nil stop_reason and subtype" do
    raw = fixture("result_success.json")
    assert {:ok, {:result, %Message.Result{} = payload}} = Claude.parse(raw)

    assert payload.stop_reason == "success"
    assert payload.usage.input_tokens == 3
    assert payload.usage.output_tokens == 7
    assert is_integer(payload.duration_ms)
  end

  test "unknown event types fallback to raw payload" do
    assert {:ok, {:raw, %Message.Raw{} = raw}} =
             Claude.parse(%{"type" => "weird_event", "x" => 1})

    assert raw.provider == :claude
    assert raw.type == "weird_event"
    assert raw.data["x"] == 1
  end

  test "non-map input returns parse error" do
    assert {:error, error} = Claude.parse("bad")
    assert error.kind == :parse_error
    assert error.domain == :parser
  end

  defp fixture(name) do
    path = Path.join([File.cwd!(), "test", "fixtures", "claude", name])
    path |> File.read!() |> Jason.decode!()
  end
end
