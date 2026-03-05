defmodule ASM.Extensions.Rendering.Sinks.CallbackTest do
  use ASM.TestCase

  alias ASM.Extensions.Rendering.Sinks.Callback
  alias ASM.Test.RenderingHelpers

  test "init/1 validates callback option" do
    assert {:error, _reason} = Callback.init([])

    callback = fn _event, _iodata -> :ok end
    assert {:ok, state} = Callback.init(callback: callback)
    assert is_map(state)
  end

  test "write_event/3 forwards event and iodata to callback" do
    test_pid = self()

    callback = fn event, iodata ->
      send(test_pid, {:callback_invoked, event.kind, IO.iodata_to_binary(iodata)})
      :ok
    end

    assert {:ok, state} = Callback.init(callback: callback)

    event = RenderingHelpers.assistant_delta("hello")
    assert {:ok, _state} = Callback.write_event(event, ["a", "b"], state)

    assert_receive {:callback_invoked, :assistant_delta, "ab"}
  end

  test "write/2, flush/1, and close/1 are safe" do
    callback = fn _event, _iodata -> :ok end
    assert {:ok, state} = Callback.init(callback: callback)

    assert {:ok, state} = Callback.write("ignored", state)
    assert {:ok, _state} = Callback.flush(state)
    assert :ok = Callback.close(state)
  end
end
