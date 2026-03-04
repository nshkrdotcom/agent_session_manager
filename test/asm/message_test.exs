defmodule ASM.MessageTest do
  use ASM.TestCase

  alias ASM.{Content, Message}

  test "assistant message requires content and accepts metadata defaults" do
    assert_raise ArgumentError, fn -> struct!(Message.Assistant, %{}) end

    message = struct!(Message.Assistant, %{content: [%Content.Text{text: "hello"}]})

    assert length(message.content) == 1
    assert message.metadata == %{}
  end

  test "result message defaults usage metadata and duration" do
    result = struct!(Message.Result, %{stop_reason: :end_turn})

    assert result.usage == %{}
    assert result.metadata == %{}
    assert result.duration_ms == nil
  end

  test "raw message payload requires provider type and data" do
    assert_raise ArgumentError, fn -> struct!(Message.Raw, %{provider: :claude, type: "x"}) end
  end
end
