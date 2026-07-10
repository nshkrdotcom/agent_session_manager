# ASM Promotion Path Examples

These examples prove the application promotion path across ASM core lane,
and ASM SDK-backed lane usage. They are live verifiers run
through Elixir APIs; they are not fake CLI fixtures.

## Examples

- `asm_core_lane.exs`: application calls ASM with `lane: :core`; no provider SDK
  is required.
- `asm_sdk_backed_lane.exs`: application calls ASM with `lane: :sdk`; the
  optional provider SDK may be loaded internally, but the call site remains ASM.

SDK-direct proof remains owned by the SDK repos:

- `claude_agent_sdk/examples/promotion_path/sdk_direct_claude.exs`
- `codex_sdk/examples/promotion_path/sdk_direct_codex.exs`
- `amp_sdk/examples/promotion_path/sdk_direct_amp.exs`

Inference-via-ASM proof remains owned by the inference repo:

- `inference/examples/asm_adapter/text_only.exs`
- `inference/examples/asm_adapter/tools_unsupported.exs`

## Live Commands

```bash
mix run --no-start examples/promotion_path/asm_core_lane.exs -- \
  --provider codex \
  --model gpt-5.6-sol \
  --prompt "Reply with exactly: ASM_CORE_LANE_OK"

mix run --no-start examples/promotion_path/asm_sdk_backed_lane.exs -- \
  --provider codex \
  --lane sdk \
  --model gpt-5.6-sol \
  --sdk-root ../codex_sdk \
  --prompt "Reply with exactly: ASM_SDK_LANE_OK"

```

All examples use the same explicit `execution_surface` carrier. Remote SSH
placement can be supplied with the shared `--ssh-*` flags handled by
`ASM.Examples.Common`.
