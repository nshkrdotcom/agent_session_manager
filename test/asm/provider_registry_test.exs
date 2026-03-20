defmodule ASM.ProviderRegistryTest do
  use ASM.TestCase

  alias ASM.ProviderRegistry

  test "supported providers resolve to core profiles" do
    assert {:ok, :claude} = ProviderRegistry.core_profile_id(:claude)
    assert {:ok, :codex} = ProviderRegistry.core_profile_id(:codex)
    assert {:ok, :gemini} = ProviderRegistry.core_profile_id(:gemini)
    assert {:ok, :amp} = ProviderRegistry.core_profile_id(:amp)
  end

  test "auto lane prefers sdk locally when available" do
    assert {:ok, resolution} =
             ProviderRegistry.resolve(:claude, lane: :auto, execution_mode: :local)

    assert resolution.lane in [:core, :sdk]
    assert resolution.backend in [ASM.ProviderBackend.Core, ASM.ProviderBackend.SDK]
  end

  test "remote execution forces the core lane for auto selection" do
    assert {:ok, resolution} =
             ProviderRegistry.resolve(:gemini, lane: :auto, execution_mode: :remote_node)

    assert resolution.lane == :core
    assert resolution.backend == ASM.ProviderBackend.Core
  end

  test "explicit remote sdk lane is rejected" do
    assert {:error, error} =
             ProviderRegistry.resolve(:codex, lane: :sdk, execution_mode: :remote_node)

    assert error.kind == :config_invalid
    assert error.message =~ "sdk lane"
  end
end
