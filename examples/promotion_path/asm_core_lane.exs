Code.require_file("common.exs", __DIR__)

config =
  ASM.PromotionPath.Common.config!(
    Path.basename(__ENV__.file),
    "Run ASM through the core lane with no provider SDK requirement.",
    "Reply with exactly: ASM_CORE_LANE_OK"
  )

ASM.PromotionPath.Common.require_lane!(config, :core)

result =
  ASM.PromotionPath.Common.run_query!(
    config,
    config.prompt,
    "asm_core_lane"
  )

ASM.PromotionPath.Common.assert_smoke_text!(
  config,
  result,
  "ASM_CORE_LANE_OK",
  "ASM core-lane output"
)
