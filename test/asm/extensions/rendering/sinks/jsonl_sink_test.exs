defmodule ASM.Extensions.Rendering.Sinks.JSONLTest do
  use ASM.TestCase

  alias ASM.Extensions.Rendering.Sinks.JSONL
  alias ASM.Test.RenderingHelpers

  test "write_event/3 writes one JSON object per event" do
    path = temp_path("jsonl-sink")
    on_exit(fn -> _ = Elixir.File.rm(path) end)

    assert {:ok, state} = JSONL.init(path: path)
    assert {:ok, state} = JSONL.write_event(RenderingHelpers.run_started(), "", state)
    assert {:ok, state} = JSONL.write_event(RenderingHelpers.assistant_delta("hello"), "", state)
    assert {:ok, _state} = JSONL.flush(state)
    assert :ok = JSONL.close(state)

    lines =
      path
      |> Elixir.File.read!()
      |> String.split("\n", trim: true)

    assert length(lines) == 2

    [first, second] = Enum.map(lines, &Jason.decode!/1)
    assert first["kind"] == "run_started"
    assert second["kind"] == "assistant_delta"
    assert second["payload"]["delta"] == "hello"
  end

  test "write/2 ignores renderer output" do
    path = temp_path("jsonl-sink-write")
    on_exit(fn -> _ = Elixir.File.rm(path) end)

    assert {:ok, state} = JSONL.init(path: path)
    assert {:ok, state} = JSONL.write("plain text", state)
    assert {:ok, _state} = JSONL.flush(state)
    assert :ok = JSONL.close(state)

    assert Elixir.File.read!(path) == ""
  end

  defp temp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "asm-rendering-#{prefix}-#{System.unique_integer([:positive])}.jsonl"
    )
  end
end
