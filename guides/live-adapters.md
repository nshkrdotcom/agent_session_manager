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

`--danger-full-access` is the example alias for `--permission-mode bypass`.
That keeps the common ASM contract normalized while still giving the live
examples an obvious flag for remote hosts where provider-native sandboxed shell
execution is blocked by the target system.

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
./examples/run_all.sh --provider codex --ssh-host example.internal --danger-full-access
./examples/run_all.sh --provider claude --ollama --ollama-model llama3.2
./examples/run_all.sh --provider codex --ollama --ollama-model llama3.2
```

`run_all.sh` forwards extra flags to each example, so common overrides such as
`--model`, `--cli-path`, `--permission-mode`, `--danger-full-access`, and
`--cwd` can be applied once.
The common `--ollama*` flags are valid only for Claude and Codex.

For Codex, `gpt-oss:20b` remains the default validated Ollama example model,
but the live adapters also allow other installed local models such as
`llama3.2`. The common smoke examples only gate exact sentinel assertions for
validated-default Codex/Ollama models, so those broader local models should be
treated as accepted exploratory routes rather than guaranteed green smoke
targets.

## What the examples cover

- `ASM.start_session/1`
- `ASM.stream/3`
- `ASM.Stream.final_result/1`
- `ASM.query/3`
- `ASM.session_info/1`
- `ASM.health/1`
- `ASM.cost/1`
- `ASM.stop_session/1`
- prompt-result exactness for the common live smoke prompts

## Useful environment knobs

- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`, `ASM_AMP_MODEL`
- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH`, `AMP_CLI_PATH`

## Remote SSH Smoke Tests

ASM’s public transport control is the same canonical `execution_surface`
contract used by the downstream SDK repos. The live SSH smoke tests use the
shared core env vars:

```bash
CLI_SUBPROCESS_CORE_LIVE_SSH=1 \
CLI_SUBPROCESS_CORE_LIVE_SSH_DESTINATION=<ssh-host> \
mix test --only live_ssh --include live_ssh test/asm/live_ssh_test.exs
```

Optional shared-harness provider command overrides are also supported when a
remote CLI exists outside the target shell `PATH`, for example
`CLI_SUBPROCESS_CORE_LIVE_SSH_CLAUDE_COMMAND=/path/to/claude`.

That test file exercises `ASM.query/3` over both the explicit `:core` and
explicit `:sdk` Codex lanes and also checks structured SDK-lane remote failure
handling for Claude, Gemini, and Amp on a real remote `execution_surface`.

## Partial Common Features

ASM exposes the common Ollama surface through the live adapters, but only for
providers that actually support it.

- Claude: supported
- Codex: supported
- Gemini: unsupported
- Amp: unsupported

See [Common And Partial Provider Features](common-and-partial-provider-features.md)
for the discovery API and normalization semantics.
