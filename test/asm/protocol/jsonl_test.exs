defmodule ASM.Protocol.JSONLTest do
  use ExUnit.Case, async: true

  alias ASM.Protocol.JSONL

  test "extract_lines/1 returns complete lines and remainder" do
    {lines, rem} = JSONL.extract_lines(~s({"a":1}\n{"b":2}\npartial))

    assert lines == [~s({"a":1}), ~s({"b":2})]
    assert rem == "partial"
  end

  test "extract_lines/1 handles CRLF" do
    {lines, rem} = JSONL.extract_lines(~s({"a":1}\r\n{"b":2}\r\n))
    assert lines == [~s({"a":1}), ~s({"b":2})]
    assert rem == ""
  end

  test "decode_line/1 decodes JSON objects and rejects non-objects" do
    assert {:ok, %{"ok" => true}} = JSONL.decode_line(~s({"ok":true}))
    assert {:error, :not_json_object} = JSONL.decode_line("[1,2,3]")
  end

  test "encode/1 emits newline-delimited JSON" do
    line = JSONL.encode(%{"x" => 1})
    assert String.ends_with?(line, "\n")
    assert {:ok, %{"x" => 1}} = JSONL.decode_line(String.trim_trailing(line, "\n"))
  end
end
