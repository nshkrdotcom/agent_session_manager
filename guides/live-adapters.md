# Live Adapter Guide

This guide covers running ASM against real provider CLIs through the common public surface.

## Prerequisites

Install provider CLIs and authenticate each one:

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @google/gemini-cli
npm install -g @openai/codex
npm install -g @sourcegraph/amp
```

Optional explicit binary paths:

- `CLAUDE_CLI_PATH`
- `GEMINI_CLI_PATH`
- `CODEX_PATH`
- `AMP_CLI_PATH`

## Example Behavior

The examples are provider-agnostic and require `--provider`. If you do not pass
a provider, they print usage and exit without touching a live CLI.

They also default to `permission_mode: :bypass` unless you override it with
`--permission-mode` or `ASM_PERMISSION_MODE`.

At startup, the examples print the normalized ASM permission mode plus the
provider-native permission term and CLI flag.

## Run one example

```bash
mix run --no-start examples/live_query.exs -- --provider claude
mix run --no-start examples/live_stream.exs -- --provider gemini
mix run --no-start examples/live_session_lifecycle.exs -- --provider codex
mix run --no-start examples/live_stream.exs -- --provider amp --prompt "Reply with exactly: AMP_STREAM_OK"
```

## Run every example for selected providers

```bash
./examples/run_all.sh --provider claude
./examples/run_all.sh --provider claude --provider gemini
./examples/run_all.sh --provider codex --model gpt-5.4
./examples/run_all.sh --provider claude --ollama --ollama-model llama3.2
```

`run_all.sh` forwards extra flags to each example, so common overrides such as
`--model`, `--cli-path`, `--permission-mode`, and `--cwd` can be applied once.
The common `--ollama*` flags are valid only for Claude and Codex.

## What the examples cover

- `ASM.start_session/1`
- `ASM.stream/3`
- `ASM.Stream.final_result/1`
- `ASM.query/3`
- `ASM.session_info/1`
- `ASM.health/1`
- `ASM.cost/1`
- `ASM.stop_session/1`

## Useful environment knobs

- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`, `ASM_AMP_MODEL`
- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH`, `AMP_CLI_PATH`

## Partial Common Features

ASM exposes the common Ollama surface through the live adapters, but only for
providers that actually support it.

- Claude: supported
- Codex: supported
- Gemini: unsupported
- Amp: unsupported

See [Common And Partial Provider Features](common-and-partial-provider-features.md)
for the discovery API and normalization semantics.
