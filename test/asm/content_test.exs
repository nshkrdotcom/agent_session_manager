defmodule ASM.ContentTest do
  use ExUnit.Case, async: true

  alias ASM.Content

  test "text struct requires text key" do
    assert_raise ArgumentError, fn -> struct!(Content.Text, %{}) end

    text = struct!(Content.Text, %{text: "hello"})
    assert text.text == "hello"
  end

  test "tool result defaults is_error to false" do
    result = struct!(Content.ToolResult, %{tool_id: "tool-1", content: %{ok: true}})
    assert result.is_error == false
  end
end
