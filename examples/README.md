# Examples

These examples cover two surfaces:

- three provider-agnostic live examples on ASM's common API
- four provider-specific examples that intentionally cross into one provider's
  SDK-native surface

Nothing runs by default. Every example requires `--provider`.

## Included Examples

- `live_query.exs`: one-off `ASM.query/3`
- `live_stream.exs`: `ASM.start_session/1`, `ASM.stream/3`,
  `ASM.Stream.final_result/1`, `ASM.stop_session/1`
- `live_session_lifecycle.exs`: `ASM.start_session/1`, `ASM.session_info/1`,
  `ASM.health/1`, `ASM.stream/3`, `ASM.query/3`, `ASM.cost/1`,
  `ASM.stop_session/1`
- `provider_amp_sdk_stream.exs`: direct `AmpSdk.execute/2`
- `provider_claude_control_client.exs`: `ASM.Extensions.ProviderSDK.Claude`
  control-client bridge
- `provider_codex_app_server.exs`: `ASM.Extensions.ProviderSDK.Codex`
  app-server bridge
- `provider_gemini_session_resume.exs`: direct `GeminiCliSdk.execute/2` and
  `GeminiCliSdk.resume_session/3`
- `run_all.sh`: runs the full example set for one or more selected providers

## Default Behavior

If you omit `--provider`, the example prints usage and exits without touching a
live CLI.

That is deliberate. The examples never silently pick a provider for you.

## Permission Defaults

All ASM examples in this directory default to `permission_mode: :bypass` unless
you override it with `--permission-mode` or `ASM_PERMISSION_MODE`.

At startup, each example prints:

- the normalized ASM permission mode
- the provider-native permission term
- the provider-native CLI flag, when one exists

Examples:

- Claude: `:bypass` -> `:bypass_permissions` -> `--permission-mode bypassPermissions`
- Gemini: `:bypass` -> `:yolo` -> `--yolo`
- Codex: `:bypass` -> `:yolo` -> `--dangerously-bypass-approvals-and-sandbox`
- Amp: `:bypass` -> `:dangerously_allow_all` -> `--dangerously-allow-all`

## Common Ollama Surface

The ASM common Ollama flags are available on the example CLI:

- `--ollama`
- `--ollama-model <name>`
- `--ollama-base-url <url>`
- `--ollama-http`
- `--ollama-timeout-ms <ms>`

That surface is intentionally partial.

Supported:

- Claude
- Codex

Unsupported:

- Gemini
- Amp

`run_all.sh` rejects `--ollama*` flags immediately for unsupported providers.

## Run One Example

```bash
mix run --no-start examples/live_query.exs -- --provider claude
mix run --no-start examples/live_stream.exs -- --provider gemini
mix run --no-start examples/live_session_lifecycle.exs -- --provider codex --model gpt-5.4
mix run --no-start examples/live_query.exs -- --provider codex --ollama --ollama-model llama3.2
mix run --no-start examples/live_query.exs -- --provider amp --lane sdk --sdk-root ../amp_sdk
mix run --no-start examples/provider_codex_app_server.exs -- --provider codex --ollama --ollama-model llama3.2
```

Shared flags:

- `--lane <core|auto|sdk>` for common-surface examples
- `--prompt <text>`
- `--model <name>`
- `--cli-path <path|command>`
- `--permission-mode <mode>`
- `--cwd <path>`
- `--sdk-root <path>`

## Run All Examples

```bash
./examples/run_all.sh --provider claude
./examples/run_all.sh --provider codex --model gpt-5.4
./examples/run_all.sh --provider claude --provider codex --ollama --ollama-model llama3.2
./examples/run_all.sh --provider amp --lane sdk --sdk-root ../amp_sdk
```

`run_all.sh` forwards extra flags to every selected example.

## Environment

- `CLAUDE_CLI_PATH`, `ASM_CLAUDE_MODEL`
- `GEMINI_CLI_PATH`, `ASM_GEMINI_MODEL`
- `CODEX_PATH`, `ASM_CODEX_MODEL`
- `AMP_CLI_PATH`, `ASM_AMP_MODEL`
- `ASM_PERMISSION_MODE`
- `CLAUDE_AGENT_SDK_ROOT`, `CODEX_SDK_ROOT`, `GEMINI_CLI_SDK_ROOT`,
  `AMP_SDK_ROOT`

The examples preflight the selected CLI before they start a session and print an
install hint if it is missing.
