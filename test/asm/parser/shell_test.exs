defmodule ASM.Parser.ShellTest do
  use ASM.TestCase

  alias ASM.Message
  alias ASM.Parser.Shell

  test "parses shell stdout line map into assistant_delta payload" do
    raw = %{"type" => "shell.output", "stream" => "stdout", "line" => "hello"}

    assert {:ok, {:assistant_delta, %Message.Partial{} = payload}} = Shell.parse(raw)
    assert payload.content_type == :text
    assert payload.delta == "hello\n"
  end

  test "unknown shell events fall back to raw payload" do
    assert {:ok, {:raw, %Message.Raw{} = raw}} = Shell.parse(%{"type" => "odd", "x" => 1})

    assert raw.provider == :shell
    assert raw.type == "odd"
    assert raw.data["x"] == 1
  end
end
