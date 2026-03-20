<p align="center">
  <img src="assets/agent_session_manager.svg" alt="Agent Session Manager" />
</p>

# ASM (Agent Session Manager)

`ASM` is an OTP-native Elixir runtime for running multi-turn AI sessions across multiple CLI providers with one API.

Supported providers:

- Claude CLI
- Gemini CLI
- Codex CLI (`exec` mode)
- Amp CLI

## Why ASM

- One session/runtime model across providers.
- Shared core event vocabulary from `cli_subprocess_core`, wrapped in run/session-scoped `%ASM.Event{}` envelopes.
- Native Elixir streaming (`Enumerable`) with reducer-based result projections.
- Provider registry that resolves providers onto backend lanes instead of provider-specific command/parser ownership.
- Remote-node execution that starts provider backends remotely while keeping the ASM session/run processes local.

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
- Provider options: validated against provider schemas and handed to the resolved backend lane.

Per-run options override session defaults. Session defaults are inherited automatically.

Runtime execution path:

- `ASM.ProviderRegistry` resolves the provider onto `:core` or `:sdk`.
- `ASM.ProviderBackend.Core` runs `cli_subprocess_core` and is the required lane for `:remote_node`.
- `ASM.ProviderBackend.SDK` runs optional provider runtime kits when they are available locally.
- `ASM.Run.Server` starts the resolved backend, subscribes to backend events, wraps core events in `%ASM.Event{}`, and applies pipelines/reducers.
- `ASM.Session.Server` remains aggregate root for run admission, approval routing, and session-level cost accounting.

## Remote Node Execution

Remote execution is opt-in per session or per run. Local mode remains the default.

Session-level remote default:

```elixir
{:ok, session} =
  ASM.start_session(
    provider: :codex,
    execution_mode: :remote_node,
    # Phase 1 keeps remote backend options under :driver_opts
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

Remote execution options:

- `remote_node` (required for `:remote_node`)
- `remote_cookie` (optional)
- `remote_connect_timeout_ms` (default `5000`)
- `remote_rpc_timeout_ms` (default `15000`)
- `remote_boot_lease_timeout_ms` (default `10000`)
- `remote_bootstrap_mode` (`:require_prestarted` | `:ensure_started`, default `:require_prestarted`)
- `remote_cwd` (optional remote workspace override)
- `remote_transport_call_timeout_ms` (backend control call timeout override)

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
- `transport_timeout_ms` (core lane subprocess/session timeout)
- `transport_headless_timeout_ms` (core lane subprocess headless timeout)

Provider-specific examples:

- Claude: `model`, `include_thinking`, `max_turns`
- Gemini: `model`, `sandbox`, `extensions`
- Codex: `model`, `reasoning_effort`, `output_schema`
- Amp: `model`, `mode`, `include_thinking`, `tools`

## Live Examples

Run real CLI smoke tests:

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/check_amp_provider.exs
mix run examples/live_multi_provider_smoke.exs
mix run examples/live_feature_matrix.exs
mix run examples/live_main_compat_migration.exs
mix run examples/live_persistence_stream.exs -- "Reply with exactly: PERSIST_OK"
mix run examples/live_rendering_stream.exs -- "Reply with exactly: RENDER_OK"
mix run examples/live_pub_sub_stream.exs -- "Reply with exactly: PUBSUB_OK"
```

Supplemental SDK-lane demo:

```bash
mix run examples/sdk_backend_demo.exs
```

Environment knobs used by examples:

- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH`, `AMP_CLI_PATH`
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`, `ASM_AMP_MODEL`
- `ASM_GEMINI_EXTENSIONS`, `ASM_CODEX_REASONING`
- `ASM_AMP_MODE`, `ASM_AMP_TOOLS`, `ASM_AMP_THINKING`, `ASM_AMP_RUN_LIVE`
- `ASM_PERSIST_PROVIDER`, `ASM_PERSIST_FILE`, `ASM_PERSIST_KEEP_FILE`
- `ASM_RENDER_PROVIDER`, `ASM_RENDER_FORMAT`, `ASM_RENDER_FILE`, `ASM_RENDER_KEEP_FILE`
- `ASM_PUBSUB_PROVIDER`

## Guides

- [Boundary Enforcement](guides/boundary-enforcement.md)
- [Live Adapter Feature Matrix](guides/live-adapters.md)
- [Remote Node Execution](guides/remote-node-execution.md)

## Architecture Notes

Per-session subtree strategy uses `:rest_for_one`:

- `ASM.Run.Supervisor`
- `ASM.Session.Server`

Run workers are `restart: :temporary` to avoid restart loops after normal completion.

Remote backend sessions are supervised on the remote node, and startup is performed through the remote backend starter.

## Quality Gates

```bash
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
mix docs
```
