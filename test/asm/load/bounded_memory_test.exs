defmodule ASM.Load.BoundedMemoryTest do
  use ExUnit.Case, async: true

  alias ASM.Transport
  alias ASM.Transport.Port

  test "transport queue remains bounded under sustained load" do
    assert {:ok, port} = Port.start_link(queue_limit: 64, overflow_policy: :drop_oldest)
    assert {:ok, :attached} = Transport.attach(port, self())

    {:memory, before_bytes} = Process.info(port, :memory)

    Enum.each(1..5_000, fn index ->
      assert :ok = Port.inject(port, %{"n" => index})
    end)

    state = :sys.get_state(port)
    assert :queue.len(state.queue) == 64

    {:memory, after_bytes} = Process.info(port, :memory)
    assert after_bytes < before_bytes + 2_000_000
  end
end
