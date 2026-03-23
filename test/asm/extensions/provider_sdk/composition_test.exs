defmodule ASM.Extensions.ProviderSDK.CompositionTest do
  use ASM.SerialTestCase

  alias ASM.Extensions.ProviderSDK
  alias ASM.Provider
  alias ASM.ProviderRegistry

  @providers [:amp, :claude, :codex, :gemini]

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

  test "common-only composition keeps ASM usable with no provider SDKs active" do
    put_loaded_providers([])

    assert {:ok, session} = ASM.start_session(provider: :gemini)
    assert {:ok, info} = ASM.session_info(session)
    assert info.provider == :gemini
    assert :ok = ASM.stop_session(session)

    assert ProviderSDK.available_extensions() == []

    assert Enum.sort(Map.keys(ProviderSDK.capability_report())) == @providers

    for provider <- @providers do
      assert {:ok, provider_info} = ProviderRegistry.provider_info(provider)
      assert provider_info.available_lanes == [:core]
      assert provider_info.sdk_available? == false

      report = Map.fetch!(ProviderSDK.capability_report(), provider)
      assert report.sdk_available? == false
      assert report.namespaces == []
      assert report.extensions == []
      assert report.native_capabilities == []
      assert report.native_surface_modules == []
    end
  end

  test "a single optional provider dependency activates only its matching native extension" do
    put_loaded_providers([:claude])

    assert {:ok, claude_info} = ProviderRegistry.provider_info(:claude)
    assert claude_info.available_lanes == [:core, :sdk]

    assert {:ok, codex_info} = ProviderRegistry.provider_info(:codex)
    assert codex_info.available_lanes == [:core]

    assert Enum.map(ProviderSDK.available_extensions(), & &1.provider) == [:claude]
    assert ProviderSDK.available?(:claude)
    refute ProviderSDK.available?(:codex)

    assert {:ok, [:control_client, :control_protocol, :hooks, :permission_callbacks]} =
             ProviderSDK.provider_capabilities(:claude)

    assert {:ok, []} = ProviderSDK.provider_capabilities(:codex)

    report = ProviderSDK.capability_report()

    assert report.claude.sdk_available? == true
    assert report.claude.namespaces == [ASM.Extensions.ProviderSDK.Claude]

    assert report.codex.sdk_available? == false
    assert report.codex.namespaces == []

    assert report.gemini.sdk_available? == false
    assert report.gemini.namespaces == []

    assert report.amp.sdk_available? == false
    assert report.amp.namespaces == []
  end

  test "all optional provider dependencies compose without inventing Gemini or Amp native namespaces" do
    put_loaded_providers(@providers)

    report = ProviderSDK.capability_report()

    assert Enum.map(ProviderSDK.available_extensions(), & &1.provider) == [:claude, :codex]

    assert report.claude.sdk_available? == true
    assert report.claude.namespaces == [ASM.Extensions.ProviderSDK.Claude]

    assert report.codex.sdk_available? == true
    assert report.codex.namespaces == [ASM.Extensions.ProviderSDK.Codex]

    assert report.gemini.sdk_available? == true
    assert report.gemini.namespaces == []
    assert report.gemini.extensions == []
    assert report.gemini.native_capabilities == []

    assert report.amp.sdk_available? == true
    assert report.amp.namespaces == []
    assert report.amp.extensions == []
    assert report.amp.native_capabilities == []
  end

  test "provider-native extension activation reports only active namespaces while preserving the static catalog" do
    put_loaded_providers([:codex])

    assert Enum.map(ProviderSDK.extensions(), & &1.provider) == [:claude, :codex]
    assert Enum.map(ProviderSDK.available_extensions(), & &1.provider) == [:codex]

    assert {:ok, extension} = ProviderSDK.extension(:codex)
    assert extension.sdk_available? == true

    assert {:ok, [registered_extension]} = ProviderSDK.provider_extensions(:codex)
    assert registered_extension.namespace == ASM.Extensions.ProviderSDK.Codex
    assert registered_extension.sdk_available? == true

    report = ProviderSDK.capability_report()

    assert report.codex.namespaces == [ASM.Extensions.ProviderSDK.Codex]
    assert report.claude.namespaces == []
  end

  defp put_loaded_providers(providers) when is_list(providers) do
    loaded_runtimes =
      providers
      |> Enum.map(&Provider.resolve!/1)
      |> Enum.map(& &1.sdk_runtime)
      |> MapSet.new()

    Application.put_env(
      :agent_session_manager,
      ASM.ProviderRegistry,
      runtime_loader: fn runtime ->
        MapSet.member?(loaded_runtimes, runtime)
      end
    )
  end
end
