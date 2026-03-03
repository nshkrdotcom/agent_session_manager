defmodule ASM.Parser.CodexTest do
  use ExUnit.Case, async: true

  alias ASM.Message
  alias ASM.Parser.Codex

  test "parses assistant delta fixture" do
    raw = fixture("assistant_delta.json")
    assert {:ok, {:assistant_delta, %Message.Partial{} = payload}} = Codex.parse(raw)
    assert payload.delta == "codex chunk"
    assert payload.content_type == :text
  end

  test "parses result fixture" do
    raw = fixture("result.json")
    assert {:ok, {:result, %Message.Result{} = payload}} = Codex.parse(raw)
    assert payload.stop_reason == "end_turn"
    assert payload.usage.input_tokens == 12
  end

  test "parses current codex item.completed agent message payloads" do
    raw = %{
      "type" => "item.completed",
      "item" => %{
        "id" => "item_1",
        "type" => "agent_message",
        "text" => "CODEX_OK"
      }
    }

    assert {:ok, {:assistant_message, %Message.Assistant{} = payload}} = Codex.parse(raw)
    assert [%ASM.Content.Text{text: "CODEX_OK"}] = payload.content
  end

  test "parses current codex turn.completed payloads with normalized stop reason" do
    raw = %{
      "type" => "turn.completed",
      "usage" => %{"input_tokens" => 8, "output_tokens" => 3}
    }

    assert {:ok, {:result, %Message.Result{} = payload}} = Codex.parse(raw)
    assert payload.stop_reason == :end_turn
    assert payload.usage.input_tokens == 8
    assert payload.usage.output_tokens == 3
  end

  test "parses tool use fixture" do
    raw = fixture("tool_use.json")
    assert {:ok, {:tool_use, %Message.ToolUse{} = payload}} = Codex.parse(raw)
    assert payload.tool_name == "bash"
    assert payload.tool_id == "tool-1"
    assert payload.input["command"] == "ls -la"
  end

  test "unknown event types fallback to raw payload" do
    assert {:ok, {:raw, %Message.Raw{} = raw}} = Codex.parse(%{"type" => "odd_event", "x" => 1})
    assert raw.provider == :codex_exec
    assert raw.type == "odd_event"
    assert raw.data["x"] == 1
  end

  defp fixture(name) do
    path = Path.join([File.cwd!(), "test", "fixtures", "codex", name])
    path |> File.read!() |> Jason.decode!()
  end
end
