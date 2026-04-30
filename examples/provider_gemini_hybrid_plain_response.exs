Code.require_file("common.exs", __DIR__)

alias ASM.Extensions.ProviderSDK.Gemini, as: GeminiBridge

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run ASM common configuration through Gemini's SDK-native plain-response extension path.",
    "Reply with exactly: GEMINI_HYBRID_OK",
    provider_sdk?: true
  )

ASM.Examples.Common.assert_provider!(config, :gemini)

ASM.Examples.Common.ensure_provider_sdk_loaded!(:gemini,
  sdk_root: config.sdk_root,
  cli_path: Keyword.get(config.session_opts, :cli_path)
)

gemini_sdk = Module.concat(["GeminiCliSdk"])
settings_profiles = Module.concat(["GeminiCliSdk", "SettingsProfiles"])

asm_common =
  Keyword.take(config.session_opts, [
    :model,
    :cwd,
    :cli_path,
    :execution_surface,
    :transport_timeout_ms
  ])

native_overrides = [
  settings: apply(settings_profiles, :plain_response, []),
  skip_trust: true
]

{:ok, options} = GeminiBridge.derive_options(asm_common, native_overrides: native_overrides)
{:ok, result_text} = apply(gemini_sdk, :run, [config.prompt, options])

ASM.Examples.Common.assert_exact_text!(result_text, "GEMINI_HYBRID_OK",
  label: "Gemini hybrid plain-response output"
)

IO.puts("provider=gemini")
IO.puts("extension=#{inspect(GeminiBridge)}")
IO.puts("model=#{inspect(Map.get(options, :model))}")
IO.puts("execution_surface=#{inspect(Map.get(options, :execution_surface))}")
IO.puts("result_text=#{inspect(result_text)}")
