defmodule AgentSessionManager.Examples.AshSessionStoreExampleTest do
  use ExUnit.Case, async: true

  test "ash example is explicitly gated behind opt-in env var" do
    content = File.read!("examples/ash_session_store.exs")
    assert content =~ "ASM_RUN_ASH_EXAMPLE"
  end
end
