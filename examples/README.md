# Live Examples

These examples exercise real provider CLIs through the `ASM.stream/3` runtime path.

## Run

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/check_amp_provider.exs
mix run examples/live_multi_provider_smoke.exs
mix run examples/live_feature_matrix.exs
mix run examples/live_main_compat_migration.exs
mix run examples/live_persistence_stream.exs -- "Reply with exactly: PERSIST_OK"
mix run examples/live_routing_round_robin.exs
mix run examples/live_routing_failover.exs
mix run examples/live_policy_stream.exs
mix run examples/live_rendering_stream.exs -- "Reply with exactly: RENDER_OK"
mix run examples/live_pub_sub_stream.exs -- "Reply with exactly: PUBSUB_OK"
mix run examples/live_workspace_snapshot.exs -- "Reply with exactly: WORKSPACE_OK"
```

Supplemental SDK-lane example:

```bash
mix run examples/sdk_backend_demo.exs
```

## Environment

- `CLAUDE_CLI_PATH` (optional explicit path)
- `GEMINI_CLI_PATH` (optional explicit path)
- `CODEX_PATH` (optional explicit path)
- `AMP_CLI_PATH` (optional explicit path)
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`; defaults to `auto`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL` (optional)
- `ASM_CODEX_REASONING` (`low`, `medium`, `high`; optional and auto-skipped when unsupported)
- `ASM_PERSIST_PROVIDER` (`claude`, `gemini`, `codex`; optional, defaults to `claude`)
- `ASM_PERSIST_FILE` (optional persistence file path override)
- `ASM_PERSIST_KEEP_FILE` (`1`/`true` to retain file after run)
- `ASM_POLICY_PROVIDER` (`claude`, `gemini`, `codex`; optional, defaults to `codex`)
- `ASM_POLICY_BUDGET_PROMPT` (optional override for budget-limit scenario prompt)
- `ASM_POLICY_TOOL_PROMPT` (optional override for denied-tool scenario prompt)
- `ASM_RENDER_PROVIDER` (`claude`, `gemini`, `codex`; optional, defaults to `claude`)
- `ASM_RENDER_FORMAT` (`compact`, `verbose`; optional, defaults to `compact`)
- `ASM_RENDER_FILE` (optional output file path for rendering sink)
- `ASM_RENDER_KEEP_FILE` (`1`/`true` to retain the render output file)
- `ASM_PUBSUB_PROVIDER` (`claude`, `gemini`, `codex`; optional, defaults to `claude`)
- `ASM_WORKSPACE_PROVIDER` (`claude`, `gemini`, `codex`; optional, defaults to `codex`)
- `ASM_WORKSPACE_DIR` (optional workspace path override for the snapshot example)
- `ASM_WORKSPACE_KEEP_DIR` (`1`/`true` to retain the temporary workspace directory)
- `ASM_AMP_MODEL` (optional Amp model identifier)
- `ASM_AMP_MODE` (optional Amp mode, default `smart`)
- `ASM_AMP_THINKING` (`1`/`true` enables Amp thinking)
- `ASM_AMP_TOOLS` (optional comma-separated Amp tool allow-list)
- `ASM_AMP_RUN_LIVE` (`1`/`true` to run a live Amp stream after contract checks)

Each script checks CLI availability first and exits with actionable setup errors if missing.
Claude streams automatically use the `script` PTY wrapper when available, and fall back to direct execution when PTY setup is unavailable.

## Coverage

- `live_claude_stream.exs`, `live_gemini_stream.exs`, `live_codex_stream.exs`: provider-specific stream flow.
- `check_amp_provider.exs`: Amp provider registry/backend checks with optional live stream check when CLI is available.
- `live_multi_provider_smoke.exs`: stream + one-shot `ASM.query/3` across all providers.
- `live_feature_matrix.exs`: session lifecycle surface on live adapters (`start_session`, `stream`, `query`, `health`, `cost`, `stop_session`).
- `live_main_compat_migration.exs`: main-shape migration helper flow (`input/messages` conversion, legacy event callback bridging, and explicit Amp/Shell unsupported checks) on live Claude/Gemini/Codex adapters.
- `live_persistence_stream.exs`: file-backed persistence with async writer hook, replay/rebuild checks, controlled error path, and guaranteed cleanup.
- `live_routing_round_robin.exs`: deterministic routing selection over live provider runs.
- `live_routing_failover.exs`: health-aware failover where an intentionally unavailable primary candidate falls back to a live provider.
- `live_policy_stream.exs`: policy enforcer behavior on live streams, including output-budget warning and denied-tool cancellation scenarios.
- `live_rendering_stream.exs`: rendering extension on live adapters with compact/verbose output streamed to terminal and file sinks.
- `live_pub_sub_stream.exs`: PubSub broadcaster wired through the run pipeline, with local topic subscription and realtime message consumption output.
- `live_workspace_snapshot.exs`: pre/post workspace snapshots around a live query, diff verification, rollback, and temporary workspace cleanup.
- `sdk_backend_demo.exs`: supplemental SDK-lane stream demonstration using `lane: :sdk`.
