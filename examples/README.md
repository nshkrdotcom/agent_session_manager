# Live Examples

These examples exercise real provider CLIs through the `ASM.stream/3` runtime path.

## Run

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/live_multi_provider_smoke.exs
```

## Environment

- `CLAUDE_CLI_PATH` (optional explicit path)
- `GEMINI_CLI_PATH` (optional explicit path)
- `CODEX_PATH` (optional explicit path)
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`; defaults to `auto`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL` (optional)
- `ASM_CODEX_REASONING` (`low`, `medium`, `high`; optional and auto-skipped when unsupported)

Each script checks CLI availability first and exits with actionable setup errors if missing.
