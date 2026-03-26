# Examples

These examples stay on the common `agent_session_manager` surface. They are intentionally provider-agnostic and only run when you explicitly choose a provider with `--provider`.

## Included examples

- `live_query.exs`: one-off `ASM.query/3` against a selected provider.
- `live_stream.exs`: `ASM.start_session/1`, `ASM.stream/3`, `ASM.Stream.final_result/1`, and `ASM.stop_session/1`.
- `live_session_lifecycle.exs`: `ASM.start_session/1`, `ASM.session_info/1`, `ASM.health/1`, `ASM.stream/3`, `ASM.query/3`, `ASM.cost/1`, and `ASM.stop_session/1`.
- `provider_amp_sdk_stream.exs`: direct `AmpSdk.execute/2` stream against the Amp-native SDK surface.
- `provider_claude_control_client.exs`: `ASM.Extensions.ProviderSDK.Claude.start_client/3` and Claude control-client initialization.
- `provider_codex_app_server.exs`: `ASM.Extensions.ProviderSDK.Codex.connect_app_server/3` and Codex app-server thread startup.
- `provider_gemini_session_resume.exs`: direct `GeminiCliSdk.execute/2` plus `GeminiCliSdk.resume_session/3`.
- `run_all.sh`: runs every example above for one or more selected providers.

## Default behavior

No example runs by default. If you omit `--provider`, the script prints a usage note and exits without exercising any live provider.

That behavior is deliberate so the examples do not accidentally hit a real CLI.

## Run one example

```bash
mix run --no-start examples/live_query.exs -- --provider claude
mix run --no-start examples/live_stream.exs -- --provider gemini
mix run --no-start examples/live_session_lifecycle.exs -- --provider codex
mix run --no-start examples/live_stream.exs -- --provider amp --prompt "Reply with exactly: AMP_STREAM_OK"
mix run --no-start examples/live_query.exs -- --provider amp --lane sdk --sdk-root ../amp_sdk --permission-mode bypass
mix run --no-start examples/provider_amp_sdk_stream.exs -- --provider amp --sdk-root ../amp_sdk
```

Each example also accepts:

- `--lane <core|auto|sdk>` to choose the ASM backend lane for common-surface examples
- `--prompt <text>` to override the built-in prompt
- `--model <name>` to override the provider model env var
- `--cli-path <path>` to override the provider CLI path env var
- `--permission-mode <mode>` to override `ASM_PERMISSION_MODE`
- `--cwd <path>` to run the provider from a specific working directory
- `--sdk-root <path>` to load a sibling provider SDK checkout for sdk-lane or provider-native examples

## Common Versus Provider-Native

The three `live_*` examples stay on the common `agent_session_manager` surface.

- They can still target `--lane sdk`, because lane selection is part of ASM's common API.
- If you want sdk-lane execution from this repo without adding dependencies to a host app, pass `--sdk-root` to load a sibling SDK checkout onto the code path first.

The four `provider_*` examples intentionally cross into provider-native territory.

- Claude and Codex go through `ASM.Extensions.ProviderSDK.*`.
- Gemini and Amp call the provider SDK directly because ASM does not add a separate native namespace for them today.

## Run all examples

```bash
./examples/run_all.sh --provider claude
./examples/run_all.sh --provider claude --provider gemini
./examples/run_all.sh --provider codex --model gpt-5-codex
./examples/run_all.sh --provider amp --lane sdk --sdk-root ../amp_sdk --permission-mode bypass
```

`run_all.sh` forwards any extra flags to each example, so the same `--model`, `--cli-path`, `--permission-mode`, and `--cwd` overrides work there too.

When a selected provider has a matching `provider_*` example, `run_all.sh` runs that provider-specific example after the three common-surface examples.

## Environment

- `CLAUDE_CLI_PATH`, `ASM_CLAUDE_MODEL`
- `GEMINI_CLI_PATH`, `ASM_GEMINI_MODEL`
- `CODEX_PATH`, `ASM_CODEX_MODEL`
- `AMP_CLI_PATH`, `ASM_AMP_MODEL`
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `CLAUDE_AGENT_SDK_ROOT`, `CODEX_SDK_ROOT`, `GEMINI_CLI_SDK_ROOT`, `AMP_SDK_ROOT`

The examples check CLI availability before starting a session and print an install hint if the selected provider binary is missing.
