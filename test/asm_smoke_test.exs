defmodule ASMSmokeTest do
  use ASM.TestCase

  test "app starts core supervision components" do
    assert Process.whereis(:asm_sessions)
    assert Process.whereis(ASM.Remote.BackendSupervisor)
    assert Process.whereis(ASM.Session.Supervisor)
  end
end
