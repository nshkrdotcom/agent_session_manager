defmodule ASM.Extensions.ProviderSDK.AmpTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Amp
  alias ASM.Options.{ProviderMismatchError, ProviderNativeOptionError}

  alias AmpSdk.Types.Options

  test "derive_options/2 maps common ASM configuration and keeps Amp-native overrides explicit" do
    asm_common = [
      cwd: "/tmp/asm-amp-extension",
      execution_surface: [
        surface_kind: :ssh_exec,
        transport_options: [destination: "amp.extension.example", port: 2222]
      ],
      transport_timeout_ms: 15_000
    ]

    native_overrides = [
      permissions: [],
      mcp_config: %{"mcpServers" => %{}}
    ]

    assert {:ok, %Options{} = options} =
             Amp.derive_options(asm_common, native_overrides: native_overrides)

    assert options.cwd == "/tmp/asm-amp-extension"
    assert options.execution_surface.surface_kind == :ssh_exec
    assert options.execution_surface.transport_options[:destination] == "amp.extension.example"
    assert options.stream_timeout_ms == 15_000
    assert options.permissions == []
    assert options.mcp_config == %{"mcpServers" => %{}}
  end

  test "derive_options/2 rejects provider-native settings in generic ASM input" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Amp.derive_options(cwd: "/tmp/asm-amp-extension", tools: ["Bash"])

    assert error.key == :tools
    assert error.provider == :amp
  end

  test "derive_options/2 rejects redundant provider options in strict common input" do
    assert {:error, %ProviderMismatchError{} = error} =
             Amp.derive_options(provider: :amp, cwd: "/tmp/asm-amp-extension")

    assert error.reason == :redundant_provider
  end

  test "derive_options/2 rejects native overrides that redefine ASM-derived fields" do
    assert {:error, error} =
             Amp.derive_options([cwd: "/tmp/asm-amp-extension"],
               native_overrides: [cwd: "/tmp/native"]
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert String.contains?(error.message, "native_overrides")
    assert String.contains?(error.message, ":cwd")
  end
end
