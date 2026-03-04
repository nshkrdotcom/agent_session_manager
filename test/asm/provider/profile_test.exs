defmodule ASM.Provider.ProfileTest do
  use ASM.TestCase

  alias ASM.Provider.Profile

  test "new/1 builds profile with defaults" do
    assert {:ok, profile} =
             Profile.new(
               transport_mode: :persistent_stdio,
               input_mode: :stdin,
               control_mode: :stdio_bidirectional,
               session_mode: :provider_managed
             )

    assert profile.transport_restart == :temporary
    assert profile.max_concurrent_runs == 1
    assert profile.max_queued_runs == 10
  end

  test "new/1 rejects invalid profile values" do
    assert {:error, error} =
             Profile.new(
               transport_mode: :bad,
               input_mode: :stdin,
               control_mode: :none,
               session_mode: :asm_managed
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
  end
end
