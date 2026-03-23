defmodule ASM.Extensions.ProviderSDKTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK
  alias ASM.ProviderRegistry

  test "extensions/0 exposes the built-in provider-native namespaces" do
    extensions = ProviderSDK.extensions()

    assert Enum.map(extensions, & &1.provider) == [:claude, :codex]

    assert Enum.map(extensions, & &1.namespace) == [
             ASM.Extensions.ProviderSDK.Claude,
             ASM.Extensions.ProviderSDK.Codex
           ]
  end

  test "extension/1 resolves both provider names and namespace modules" do
    assert {:ok, by_provider} = ProviderSDK.extension(:claude)
    assert {:ok, by_module} = ProviderSDK.extension(ASM.Extensions.ProviderSDK.Claude)

    assert by_provider == by_module
    assert by_provider.provider == :claude
    assert by_provider.namespace == ASM.Extensions.ProviderSDK.Claude
    assert by_provider.native_capabilities == [:control_protocol, :hooks, :permission_callbacks]
  end

  test "provider_extensions/1 resolves provider aliases and preserves kernel/provider split" do
    assert {:ok, [extension]} = ProviderSDK.provider_extensions(:codex_exec)
    assert {:ok, provider_info} = ProviderRegistry.provider_info(:codex)

    assert extension.provider == :codex
    assert extension.native_capabilities == [:app_server, :mcp, :realtime, :voice]

    refute Map.has_key?(provider_info, :extensions)
    refute Map.has_key?(provider_info, :native_capabilities)
    refute Map.has_key?(provider_info, :provider_sdk_extensions)
  end

  test "provider_capabilities/1 reports provider-native capability inventory" do
    assert {:ok, capabilities} = ProviderSDK.provider_capabilities(:codex)

    assert capabilities == [:app_server, :mcp, :realtime, :voice]
  end

  test "capability_report/0 groups namespaces and native surfaces by provider" do
    report = ProviderSDK.capability_report()

    assert report.claude.namespaces == [ASM.Extensions.ProviderSDK.Claude]
    assert report.claude.native_capabilities == [:control_protocol, :hooks, :permission_callbacks]

    assert report.codex.namespaces == [ASM.Extensions.ProviderSDK.Codex]

    assert report.codex.native_surface_modules == [
             Codex.AppServer,
             Codex.MCP.Client,
             Codex.Realtime,
             Codex.Voice
           ]
  end

  test "available?/1 reflects optional sdk loading without widening the kernel export list" do
    assert is_boolean(ProviderSDK.available?(:claude))
    assert is_boolean(ProviderSDK.available?(ASM.Extensions.ProviderSDK.Codex))

    refute ASM.Extensions.ProviderSDK in ASM.__boundary__(:exports)
  end

  test "extension/1 returns a config error for unknown providers" do
    assert {:error, error} = ProviderSDK.extension(:shell)

    assert error.kind == :config_invalid
    assert error.domain == :config
  end
end
