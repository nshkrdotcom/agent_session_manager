<p align="center">
  <img src="assets/agent_session_manager.svg" alt="Agent Session Manager" />
</p>

# ASM (Agent Session Manager)

`ASM` is an OTP-native Elixir runtime for running multi-turn AI sessions across multiple CLI providers with one API.

Supported providers:

- Claude CLI
- Gemini CLI
- Codex CLI (`exec` mode)
- Amp CLI (extension path)
- Shell (controlled extension path)

## Why ASM

- One session/runtime model across providers.
- Native Elixir streaming (`Enumerable`) with backpressure-friendly composition.
- Deterministic event envelopes for replay, auditing, and reducer-based projections.
- Provider-specific flags/options normalized behind a consistent API.
- Lease-aware transport boundary with bounded queue and explicit overflow policy.

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
- `AMP_CLI_PATH`
- `ASM_SHELL_PATH`

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

Runtime execution path:

- `ASM.Stream.CLIDriver` resolves provider command + starts a supervised `ASM.Transport.Port`.
- `ASM.Run.Server` owns parser dispatch and emits typed `%ASM.Event{}` envelopes.
- `ASM.Session.Server` remains aggregate root for run admission and approval routing.

## Remote Node Execution

Remote execution is opt-in per session or per run. Local mode remains the default.

Session-level remote default:

```elixir
{:ok, session} =
  ASM.start_session(
    provider: :codex,
    execution_mode: :remote_node,
    driver_opts: [
      remote_node: :"asm@sandbox-a",
      remote_cookie: :cluster_cookie,
      remote_cwd: "/workspaces/t-123"
    ]
  )
```

Per-run remote override:

```elixir
ASM.query(session, "analyze this",
  execution_mode: :remote_node,
  driver_opts: [remote_node: :"asm@sandbox-b"]
)
```

Per-run local override (when session default is remote):

```elixir
ASM.query(session, "quick local check", execution_mode: :local)
```

Remote driver options:

- `remote_node` (required for `:remote_node`)
- `remote_cookie` (optional)
- `remote_connect_timeout_ms` (default `5000`)
- `remote_rpc_timeout_ms` (default `15000`)
- `remote_boot_lease_timeout_ms` (default `10000`)
- `remote_bootstrap_mode` (`:require_prestarted` | `:ensure_started`, default `:require_prestarted`)
- `remote_cwd` (optional remote workspace override)
- `remote_transport_call_timeout_ms` (transport control call timeout override)

Operational requirements for remote worker nodes:

- Erlang distribution enabled with trusted cookie
- `:agent_session_manager` available on the remote node
- provider CLI binaries installed remotely
- provider credentials available on remote host
- compatible OTP major version
- ASM major/minor compatibility

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
- Amp: `model`, `mode`, `include_thinking`, `tools`
- Shell: `allowed_commands`, `denied_commands`, `command_timeout_ms`, `success_exit_codes`

## Live Examples

Run real CLI smoke tests:

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/check_amp_provider.exs
mix run examples/live_shell_stream.exs -- "echo SHELL_OK"
mix run examples/live_multi_provider_smoke.exs
mix run examples/live_feature_matrix.exs
mix run examples/live_persistence_stream.exs -- "Reply with exactly: PERSIST_OK"
mix run examples/live_rendering_stream.exs -- "Reply with exactly: RENDER_OK"
mix run examples/live_pub_sub_stream.exs -- "Reply with exactly: PUBSUB_OK"
```

Environment knobs used by examples:

- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH`, `AMP_CLI_PATH`
- `ASM_SHELL_PATH`, `ASM_SHELL_ALLOWED`, `ASM_SHELL_DENIED`, `ASM_SHELL_TIMEOUT_MS`
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`, `ASM_AMP_MODEL`
- `ASM_GEMINI_EXTENSIONS`, `ASM_CODEX_REASONING`
- `ASM_AMP_MODE`, `ASM_AMP_TOOLS`, `ASM_AMP_THINKING`, `ASM_AMP_RUN_LIVE`
- `ASM_PERSIST_PROVIDER`, `ASM_PERSIST_FILE`, `ASM_PERSIST_KEEP_FILE`
- `ASM_RENDER_PROVIDER`, `ASM_RENDER_FORMAT`, `ASM_RENDER_FILE`, `ASM_RENDER_KEEP_FILE`
- `ASM_PUBSUB_PROVIDER`

Shell safety note: run `examples/live_shell_stream.exs` only inside a disposable sandbox/workspace.

## Guides

- [Boundary Enforcement](guides/boundary-enforcement.md)
- [Live Adapter Feature Matrix](guides/live-adapters.md)
- [Remote Node Execution](guides/remote-node-execution.md)
- [Transport Guarantees](guides/transport-guarantees.md)

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
