# Live Adapter Guide

This guide covers running ASM against real provider CLIs and validating the full public runtime surface.

## Prerequisites

Install provider CLIs and authenticate each one:

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @google/gemini-cli
npm install -g @openai/codex
```

Optional explicit binary paths:

- `CLAUDE_CLI_PATH`
- `GEMINI_CLI_PATH`
- `CODEX_PATH`
- `AMP_CLI_PATH`

## Provider-specific stream checks

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/check_amp_provider.exs
```

`check_amp_provider.exs` always runs provider wiring checks for the greenfield backend stack.
It runs a live Amp stream only when `ASM_AMP_RUN_LIVE=1` and the Amp CLI resolves.

Claude runs use a PTY wrapper (`script`) when available. If PTY setup is not usable in the current environment, ASM falls back to direct CLI execution.

## Multi-provider smoke (stream + one-shot query)

```bash
mix run examples/live_multi_provider_smoke.exs
```

## Full feature matrix on live adapters

```bash
mix run examples/live_feature_matrix.exs
mix run examples/live_main_compat_migration.exs
```

## Routing extension on live adapters

```bash
mix run examples/live_routing_round_robin.exs
mix run examples/live_routing_failover.exs
```

The failover script intentionally makes the primary router candidate unavailable by
setting an invalid CLI path and verifies fallback to a second live provider.

## Rendering extension on live adapters

```bash
mix run examples/live_rendering_stream.exs -- "Reply with exactly: RENDER_OK"
```

The rendering script consumes live `%ASM.Event{}` output and demonstrates
multi-sink composition:

- terminal output via `ASM.Extensions.Rendering.Sinks.TTY`
- file logging via `ASM.Extensions.Rendering.Sinks.File`

## PubSub extension on live adapters

```bash
mix run examples/live_pub_sub_stream.exs -- "Reply with exactly: PUBSUB_OK"
```

The PubSub script wires `ASM.Extensions.PubSub.broadcaster_plug/2` into the
run pipeline, subscribes to `asm:events` and `asm:session:<session_id>` topics,
and prints consumed `{:asm_pubsub, topic, payload}` messages.

The feature-matrix script validates:

- `ASM.start_session/1`
- `ASM.stream/3` + stream event projection
- `ASM.query/3` on an existing live session
- `ASM.health/1`
- `ASM.cost/1`
- `ASM.stop_session/1`

`live_main_compat_migration.exs` validates:

- `ASM.Migration.MainCompat` provider/input/option conversion from main-style shapes
- legacy event callback bridging over live stream output
- explicit unsupported migration errors for Amp/Shell adapter hints

## Useful environment knobs

- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`
- `ASM_GEMINI_EXTENSIONS` (comma-separated list)
- `ASM_CODEX_REASONING` (`low`, `medium`, `high`)
- `ASM_RENDER_PROVIDER` (`claude`, `gemini`, `codex`)
- `ASM_RENDER_FORMAT` (`compact`, `verbose`)
- `ASM_RENDER_FILE` (render output file path)
- `ASM_RENDER_KEEP_FILE` (`1`/`true` to keep output file)
- `ASM_PUBSUB_PROVIDER` (`claude`, `gemini`, `codex`)
- `ASM_AMP_MODEL`, `ASM_AMP_MODE`, `ASM_AMP_TOOLS`, `ASM_AMP_THINKING`
- `ASM_AMP_RUN_LIVE` (`1`/`true` enables live Amp stream check)
