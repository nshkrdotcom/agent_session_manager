# ASM (Agent Session Manager)

`ASM` is an OTP-native Elixir runtime for running multi-turn AI sessions across multiple CLI providers with one API.

Supported providers:

- Claude CLI
- Gemini CLI
- Codex CLI (`exec` mode)

## Why ASM

- One session/runtime model across providers.
- Native Elixir streaming (`Enumerable`) with backpressure-friendly composition.
- Deterministic event envelopes for replay, auditing, and reducer-based projections.
- Provider-specific flags/options normalized behind a consistent API.

## Install

```elixir
def deps do
  [
    {:agent_session_manager, path: "../agent_session_manager"}
  ]
end
```

## CLI Setup

Install provider CLIs you plan to use:

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @google/gemini-cli
npm install -g @openai/codex
```

Authenticate each CLI with its native flow before using ASM.

Optional explicit CLI paths:

- `CLAUDE_CLI_PATH`
- `GEMINI_CLI_PATH`
- `CODEX_PATH`

## Quick Start

```elixir
# OTP-friendly session startup
{:ok, session} = ASM.start_link(provider: :claude)

# Stream text chunks
session
|> ASM.stream("Reply with exactly: OK")
|> ASM.Stream.text_content()
|> Enum.each(&IO.write/1)

# Query convenience API
case ASM.query(session, "Say hello") do
  {:ok, result} -> IO.puts(result.text)
  {:error, error} -> IO.puts("failed: #{Exception.message(error)}")
end

:ok = ASM.stop_session(session)
```

Provider atom form for one-off queries:

```elixir
{:ok, result} = ASM.query(:gemini, "Say hello")
```

## Session Model

`ASM` has three option layers:

- Session defaults: passed to `ASM.start_link/1` or `ASM.start_session/1`.
- Per-run overrides: passed to `ASM.stream/3` or `ASM.query/3`.
- Provider options: validated against provider schemas and passed to CLI command builders.

Per-run options override session defaults. Session defaults are inherited automatically.

## Public API

Core lifecycle:

- `ASM.start_link/1`
- `ASM.start_session/1`
- `ASM.stop_session/1`
- `ASM.session_id/1`

Run execution:

- `ASM.stream/3`
- `ASM.query/3`

Runtime control:

- `ASM.health/1`
- `ASM.cost/1`
- `ASM.interrupt/2`
- `ASM.approve/3`

Streaming helpers:

- `ASM.Stream.final_result/1`
- `ASM.Stream.text_deltas/1`
- `ASM.Stream.text_content/1`
- `ASM.Stream.final_text/1`

## Error Semantics

`ASM.query/3` returns:

- `{:ok, %ASM.Result{...}}` when the run completes successfully.
- `{:error, %ASM.Error{...}}` for terminal run failures, transport failures, parse failures, and runtime failures.

Result projections also include structured cost and terminal error:

- `%ASM.Result{cost: %{input_tokens: ..., output_tokens: ..., cost_usd: ...}}`
- `%ASM.Result{error: %ASM.Error{} | nil}`

## Provider Options

Common options:

- `provider`
- `permission_mode` (`:default | :auto | :bypass | :plan`)
- `cli_path`
- `cwd`
- `env`
- `approval_timeout_ms`
- `transport_timeout_ms`

Provider-specific examples:

- Claude: `model`, `include_thinking`, `max_turns`
- Gemini: `model`, `sandbox`, `extensions`
- Codex: `model`, `reasoning_effort`, `output_schema`

## Live Examples

Run real CLI smoke tests:

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/live_multi_provider_smoke.exs
```

Environment knobs used by examples:

- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH`
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`

## Architecture Notes

Per-session subtree strategy uses `:rest_for_one`:

- `ASM.Session.TransportSupervisor`
- `ASM.Run.Supervisor`
- `ASM.Session.Server`

Run workers are `restart: :temporary` to avoid restart loops after normal completion.

## Quality Gates

```bash
mix format
mix test
mix credo --strict
mix dialyzer
```
