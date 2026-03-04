defmodule ASM.ControlTest do
  use ASM.TestCase

  alias ASM.Control

  test "transport status requires status and transport pid" do
    assert_raise ArgumentError, fn -> struct!(Control.TransportStatus, %{status: :opened}) end

    value = struct!(Control.TransportStatus, %{status: :opened, transport_pid: self()})
    assert value.status == :opened
    assert value.transport_pid == self()
  end

  test "backpressure requires run id and policy" do
    backpressure =
      struct!(Control.Backpressure, %{queue_size: 100, policy: :fail_run, run_id: "run-1"})

    assert backpressure.queue_size == 100
    assert backpressure.policy == :fail_run
    assert backpressure.run_id == "run-1"
  end
end
