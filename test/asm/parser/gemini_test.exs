defmodule ASM.Parser.GeminiTest do
  use ASM.TestCase

  alias ASM.Message
  alias ASM.Parser.Gemini

  test "parses assistant delta message fixture" do
    raw = fixture("message_delta.json")
    assert {:ok, {:assistant_delta, %Message.Partial{} = payload}} = Gemini.parse(raw)
    assert payload.delta == "gemini stream chunk"
    assert payload.content_type == :text
  end

  test "parses result fixture" do
    raw = fixture("result.json")
    assert {:ok, {:result, %Message.Result{} = payload}} = Gemini.parse(raw)
    assert payload.stop_reason == "completed"
    assert payload.usage.input_tokens == 9
    assert payload.usage.output_tokens == 4
  end

  test "parses tool use fixture" do
    raw = fixture("tool_use.json")
    assert {:ok, {:tool_use, %Message.ToolUse{} = payload}} = Gemini.parse(raw)
    assert payload.tool_name == "search"
    assert payload.tool_id == "tool-g-1"
    assert payload.input["q"] == "elixir otp"
  end

  test "unknown event types fallback to raw payload" do
    assert {:ok, {:raw, %Message.Raw{} = raw}} = Gemini.parse(%{"type" => "odd_event", "x" => 1})
    assert raw.provider == :gemini
    assert raw.type == "odd_event"
  end

  defp fixture(name) do
    path = Path.join([File.cwd!(), "test", "fixtures", "gemini", name])
    path |> File.read!() |> Jason.decode!()
  end
end
