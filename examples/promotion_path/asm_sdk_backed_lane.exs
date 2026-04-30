Code.require_file("common.exs", __DIR__)

config =
  ASM.PromotionPath.Common.config!(
    Path.basename(__ENV__.file),
    "Run ASM through the SDK-backed lane while keeping the call site on ASM.",
    "Reply with exactly: ASM_SDK_LANE_OK",
    provider_sdk?: true
  )

ASM.PromotionPath.Common.require_lane!(config, :sdk)
ASM.PromotionPath.Common.ensure_provider_sdk_loaded!(config)

result =
  ASM.PromotionPath.Common.run_query!(
    config,
    config.prompt,
    "asm_sdk_backed_lane"
  )

ASM.PromotionPath.Common.assert_smoke_text!(
  config,
  result,
  "ASM_SDK_LANE_OK",
  "ASM SDK-backed lane output"
)
