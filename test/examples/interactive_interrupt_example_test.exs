defmodule AgentSessionManager.Examples.InteractiveInterruptExampleTest do
  use ExUnit.Case, async: true

  setup_all do
    unless Code.ensure_loaded?(InteractiveInterruptExample) do
      {_, _binding} =
        Code.eval_string(
          File.read!("examples/interactive_interrupt.exs")
          |> String.replace(~r/^InteractiveInterruptExample\.main\(System\.argv\(\)\)$/m, ":ok"),
          [],
          file: "examples/interactive_interrupt.exs"
        )
    end

    :ok
  end

  test "wait_for_first_streamed_chunk/2 returns true when chunk arrives" do
    ref = make_ref()
    parent = self()

    spawn(fn ->
      Process.sleep(20)
      send(parent, {ref, :streamed_chunk})
    end)

    assert InteractiveInterruptExample.wait_for_first_streamed_chunk(ref, 200)
  end

  test "wait_for_first_streamed_chunk/2 returns false on timeout" do
    ref = make_ref()
    refute InteractiveInterruptExample.wait_for_first_streamed_chunk(ref, 10)
  end
end
