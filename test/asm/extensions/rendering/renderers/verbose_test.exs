defmodule ASM.Extensions.Rendering.Renderers.VerboseTest do
  use ASM.TestCase

  alias ASM.Extensions.Rendering.Renderers.Verbose
  alias ASM.Test.RenderingHelpers

  test "render_event/2 emits structured lines and streams assistant deltas" do
    events = [
      RenderingHelpers.run_started(),
      RenderingHelpers.assistant_delta("Hello"),
      RenderingHelpers.assistant_delta(" world"),
      RenderingHelpers.assistant_message("Hello world"),
      RenderingHelpers.tool_use("bash", %{"cmd" => "pwd"}),
      RenderingHelpers.tool_result("tool-rendering-1", "done"),
      RenderingHelpers.result_event(),
      RenderingHelpers.run_completed()
    ]

    assert {:ok, state} = Verbose.init(color: false)

    {chunks, state} =
      Enum.reduce(events, {[], state}, fn event, {acc, renderer_state} ->
        {:ok, iodata, next_state} = Verbose.render_event(event, renderer_state)
        {[IO.iodata_to_binary(iodata) | acc], next_state}
      end)

    assert {:ok, finish_iodata, _state} = Verbose.finish(state)

    output =
      chunks
      |> Enum.reverse()
      |> Enum.join("")
      |> Kernel.<>(IO.iodata_to_binary(finish_iodata))

    assert output =~ "[run_started]"
    assert output =~ "Hello world"
    assert output =~ "[tool_use]"
    assert output =~ "[tool_result]"
    assert output =~ "[result]"
    assert output =~ "[run_completed]"
    assert output =~ "events"
  end

  test "render_event/2 emits structured error lines for runtime errors" do
    assert {:ok, state} = Verbose.init(color: false)

    assert {:ok, iodata, state} =
             Verbose.render_event(RenderingHelpers.error_event(message: "failure"), state)

    assert IO.iodata_to_binary(iodata) =~ "[error]"
    assert IO.iodata_to_binary(iodata) =~ "failure"

    assert {:ok, _finish, _state} = Verbose.finish(state)
  end
end
