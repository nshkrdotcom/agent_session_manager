defmodule ASM.Extensions.Rendering.Renderers.CompactTest do
  use ASM.TestCase

  alias ASM.Extensions.Rendering.Renderers.Compact
  alias ASM.Test.RenderingHelpers

  test "render_event/2 emits compact tokens for lifecycle, deltas, tools, and result" do
    events = [
      RenderingHelpers.run_started(),
      RenderingHelpers.assistant_delta("Hello"),
      RenderingHelpers.assistant_delta(" world"),
      RenderingHelpers.tool_use("bash", %{"cmd" => "pwd"}),
      RenderingHelpers.tool_result("tool-rendering-1", %{"stdout" => "/tmp"}),
      RenderingHelpers.result_event(),
      RenderingHelpers.run_completed()
    ]

    assert {:ok, state} = Compact.init(color: false)

    {pieces, state} =
      Enum.reduce(events, {[], state}, fn event, {acc, renderer_state} ->
        {:ok, iodata, next_state} = Compact.render_event(event, renderer_state)
        {[IO.iodata_to_binary(iodata) | acc], next_state}
      end)

    assert {:ok, finish_iodata, _state} = Compact.finish(state)

    output =
      pieces
      |> Enum.reverse()
      |> Enum.join("")
      |> Kernel.<>(IO.iodata_to_binary(finish_iodata))

    assert output =~ "r+"
    assert output =~ ">> Hello"
    assert output =~ "world"
    assert output =~ "t+bash"
    assert output =~ "t-tool-rendering-1"
    assert output =~ "r-:end"
    assert output =~ "events"
  end

  test "render_event/2 prints compact error token for error events" do
    assert {:ok, state} = Compact.init(color: false)

    assert {:ok, iodata, state} =
             Compact.render_event(RenderingHelpers.error_event(message: "boom"), state)

    text = IO.iodata_to_binary(iodata)

    assert text =~ "!"
    assert text =~ "boom"

    assert {:ok, finish_iodata, _state} = Compact.finish(state)
    assert IO.iodata_to_binary(finish_iodata) =~ "events"
  end
end
