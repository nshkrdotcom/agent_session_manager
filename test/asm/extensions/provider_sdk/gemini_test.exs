defmodule ASM.Extensions.ProviderSDK.GeminiTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Gemini
  alias ASM.Options.{ProviderMismatchError, ProviderNativeOptionError}

  alias GeminiCliSdk.Options

  test "derive_options/2 maps common ASM configuration and keeps Gemini-native overrides explicit" do
    asm_common = [
      model: "flash-lite",
      cwd: "/tmp/asm-gemini-extension",
      cli_path: "/usr/local/bin/gemini",
      execution_surface: [
        surface_kind: :ssh_exec,
        transport_options: [destination: "gemini.extension.example", port: 2222]
      ],
      transport_timeout_ms: 12_000
    ]

    native_overrides = [
      settings: %{"tools" => %{"core" => []}},
      skip_trust: true
    ]

    assert {:ok, %Options{} = options} =
             Gemini.derive_options(asm_common, native_overrides: native_overrides)

    assert options.model in ["flash-lite", "gemini-2.5-flash-lite"]
    assert options.cwd == "/tmp/asm-gemini-extension"
    assert options.cli_command == "/usr/local/bin/gemini"
    assert options.execution_surface.surface_kind == :ssh_exec
    assert options.execution_surface.transport_options[:destination] == "gemini.extension.example"
    assert options.timeout_ms == 12_000
    assert options.settings == %{"tools" => %{"core" => []}}
    assert options.skip_trust == true
  end

  test "derive_options/2 rejects provider-native settings in generic ASM input" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Gemini.derive_options(model: "flash-lite", system_prompt: "stay native")

    assert error.key == :system_prompt
    assert error.provider == :gemini
  end

  test "derive_options/2 rejects redundant provider options in strict common input" do
    assert {:error, %ProviderMismatchError{} = error} =
             Gemini.derive_options(provider: :gemini, model: "flash-lite")

    assert error.reason == :redundant_provider
  end

  test "derive_options/2 rejects native overrides that redefine ASM-derived fields" do
    assert {:error, error} =
             Gemini.derive_options([model: "flash-lite"], native_overrides: [model: "other"])

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "native_overrides"
    assert error.message =~ ":model"
  end
end
