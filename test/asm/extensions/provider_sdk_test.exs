defmodule ASM.Extensions.ProviderSDKTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK
  alias ASM.ProviderRegistry

  setup do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    Application.put_env(
      :agent_session_manager,
      ASM.ProviderRegistry,
      runtime_loader:
        ASM.TestSupport.OptionalSDK.loaded_runtime_loader([:amp, :claude, :codex, :gemini])
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end
    end)

    :ok
  end

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

    assert by_provider.native_capabilities == [
             :control_client,
             :control_protocol,
             :hooks,
             :permission_callbacks
           ]
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

  test "claude provider_capabilities/1 includes the control-client bridge surface" do
    assert {:ok, capabilities} = ProviderSDK.provider_capabilities(:claude)

    assert capabilities == [:control_client, :control_protocol, :hooks, :permission_callbacks]
  end

  test "capability_report/0 reports all providers while keeping Gemini and Amp common-surface-only" do
    report = ProviderSDK.capability_report()

    assert report.claude.namespaces == [ASM.Extensions.ProviderSDK.Claude]

    assert report.claude.native_capabilities == [
             :control_client,
             :control_protocol,
             :hooks,
             :permission_callbacks
           ]

    assert report.claude.native_surface_modules == [
             ClaudeAgentSDK.Client,
             ClaudeAgentSDK.ControlProtocol.Protocol,
             ClaudeAgentSDK.Hooks,
             ClaudeAgentSDK.Permission
           ]

    assert report.codex.namespaces == [ASM.Extensions.ProviderSDK.Codex]

    assert report.codex.native_surface_modules == [
             Codex.AppServer,
             Codex.MCP.Client,
             Codex.Realtime,
             Codex.Voice
           ]

    assert report.gemini.sdk_available? == true
    assert report.gemini.namespaces == []
    assert report.gemini.extensions == []
    assert report.gemini.native_capabilities == []

    assert report.amp.sdk_available? == true
    assert report.amp.namespaces == []
    assert report.amp.extensions == []
    assert report.amp.native_capabilities == []
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
