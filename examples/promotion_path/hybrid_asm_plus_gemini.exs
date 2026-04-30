Code.require_file("common.exs", __DIR__)

alias ASM.Extensions.ProviderSDK.Gemini, as: GeminiBridge

config =
  ASM.PromotionPath.Common.config!(
    Path.basename(__ENV__.file),
    "Run ASM for the common flow and GeminiCliSdk for provider-native plain response.",
    "Reply with exactly: HYBRID_ASM_OK",
    provider_sdk?: true
  )

ASM.PromotionPath.Common.require_provider!(config, :gemini)
ASM.PromotionPath.Common.ensure_provider_sdk_loaded!(config)

asm_result =
  ASM.PromotionPath.Common.run_query!(
    config,
    config.prompt,
    "hybrid_asm"
  )

ASM.PromotionPath.Common.assert_smoke_text!(
  config,
  asm_result,
  "HYBRID_ASM_OK",
  "Hybrid ASM output"
)

gemini_sdk = Module.concat(["GeminiCliSdk"])
settings_profiles = Module.concat(["GeminiCliSdk", "SettingsProfiles"])

asm_common =
  config.session_opts
  |> Keyword.take([:model, :cwd, :cli_path, :execution_surface, :transport_timeout_ms])
  |> Keyword.put_new(:execution_surface, ASM.PromotionPath.Common.execution_surface(config))

native_overrides = [
  settings: apply(settings_profiles, :plain_response, []),
  skip_trust: true
]

{:ok, gemini_options} = GeminiBridge.derive_options(asm_common, native_overrides: native_overrides)
{:ok, sdk_text} = apply(gemini_sdk, :run, ["Reply with exactly: HYBRID_SDK_OK", gemini_options])

ASM.Examples.Common.assert_exact_text!(sdk_text, "HYBRID_SDK_OK",
  label: "Hybrid Gemini SDK output"
)

IO.puts("hybrid_sdk_text=#{inspect(sdk_text)}")
IO.puts("shared_execution_surface=#{inspect(Map.get(gemini_options, :execution_surface))}")
