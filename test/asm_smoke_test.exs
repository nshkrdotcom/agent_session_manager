defmodule ASMSmokeTest do
  use ExUnit.Case, async: true

  test "app starts core supervision components" do
    assert Process.whereis(:asm_sessions)
    assert Process.whereis(ASM.Session.Supervisor)
  end
end
