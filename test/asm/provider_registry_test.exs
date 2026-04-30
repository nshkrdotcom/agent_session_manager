defmodule ASM.ProviderRegistryTest do
  use ASM.SerialTestCase

  alias ASM.ProviderRegistry

  setup do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end
    end)

    :ok
  end

  test "supported providers resolve to core profiles" do
    assert {:ok, :claude} = ProviderRegistry.core_profile_id(:claude)
    assert {:ok, :codex} = ProviderRegistry.core_profile_id(:codex)
    assert {:ok, :gemini} = ProviderRegistry.core_profile_id(:gemini)
    assert {:ok, :amp} = ProviderRegistry.core_profile_id(:amp)
  end

  test "provider_info/1 exposes provider and lane discovery metadata" do
    assert {:ok, info} = ProviderRegistry.provider_info(:codex)

    assert info.provider.name == :codex
    assert info.core_profile_id == :codex
    assert info.default_lane == :auto
    assert :core in info.available_lanes
    assert info.sdk_runtime == Codex.Runtime.Exec
  end

  test "lane_info/2 resolves lane preference independently from execution mode" do
    assert {:ok, info} = ProviderRegistry.lane_info(:claude, lane: :auto)

    assert info.requested_lane == :auto
    assert info.preferred_lane in [:core, :sdk]
    assert info.backend in [ASM.ProviderBackend.Core, ASM.ProviderBackend.SDK]
  end

  test "lane_info/2 falls back to core when the sdk runtime is unavailable" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> false
      runtime -> Code.ensure_loaded?(runtime)
    end)

    assert {:ok, info} = ProviderRegistry.lane_info(:codex, lane: :auto)

    assert info.preferred_lane == :core
    assert info.sdk_available? == false
    assert info.lane_reason == :sdk_unavailable
  end

  test "lane_info/2 does not load provider SDK runtimes for explicit core lane" do
    put_runtime_loader(fn
      GeminiCliSdk.Runtime.CLI -> flunk("explicit core lane must not probe Gemini SDK")
      runtime -> Code.ensure_loaded?(runtime)
    end)

    assert {:ok, info} = ProviderRegistry.lane_info(:gemini, lane: :core)

    assert info.requested_lane == :core
    assert info.preferred_lane == :core
    assert info.backend == ASM.ProviderBackend.Core
    assert info.sdk_available? == false
    assert info.lane_reason == :explicit_core
  end

  test "explicit local sdk lane fails with stable unavailable cause when runtime is absent" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> false
      runtime -> Code.ensure_loaded?(runtime)
    end)

    assert {:error, error} = ProviderRegistry.resolve(:codex, lane: :sdk)

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.provider == :codex
    assert %ASM.ProviderBackend.SdkUnavailableError{} = cause = error.cause
    assert cause.provider == :codex
    assert cause.runtime == Codex.Runtime.Exec
    assert cause.lane == :sdk
    assert cause.reason == :sdk_unavailable
  end

  test "resolve/2 applies remote compatibility after lane selection" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    assert {:ok, resolution} =
             ProviderRegistry.resolve(:codex, lane: :auto, execution_mode: :remote_node)

    assert resolution.preferred_lane == :sdk
    assert resolution.lane == :core
    assert resolution.lane_fallback_reason == :sdk_remote_unsupported
    assert resolution.backend == ASM.ProviderBackend.Core
  end

  test "explicit remote sdk lane is rejected after lane selection" do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    assert {:error, error} =
             ProviderRegistry.resolve(:codex, lane: :sdk, execution_mode: :remote_node)

    assert error.kind == :config_invalid
    assert error.message =~ "sdk lane"
    assert %ASM.ProviderBackend.SdkUnavailableError{} = error.cause
    assert error.cause.provider == :codex
    assert error.cause.reason == :unsupported_execution_mode
  end

  defp put_runtime_loader(fun) when is_function(fun, 1) do
    Application.put_env(:agent_session_manager, ASM.ProviderRegistry, runtime_loader: fun)
  end
end
