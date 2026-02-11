defmodule AgentSessionManager.Runtime.ExitReasonsTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Runtime.ExitReasons

  test "adapter_unavailable?/1 matches expected exit patterns" do
    assert ExitReasons.adapter_unavailable?(:noproc)
    assert ExitReasons.adapter_unavailable?({:noproc, :ignored})
    assert ExitReasons.adapter_unavailable?({:shutdown, {:noproc, :ignored}})
    assert ExitReasons.adapter_unavailable?({:shutdown, :normal})
    refute ExitReasons.adapter_unavailable?(:timeout)
  end
end
