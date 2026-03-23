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
    {:agent_session_manager, "~> 0.10.0"}
  ]
end
```

For local workspace development, replace that published requirement with the
repo-local `path:` override.

That dependency is the normalized kernel plus the built-in Phase 2B extension
namespaces.

Optional provider-native rich surfaces stay in provider SDK packages. Add a
provider SDK dependency only when you explicitly want its SDK-local family:

- `{:claude_agent_sdk, "~> 0.16.0", optional: true}` for Claude control-protocol
  helpers
- `{:codex_sdk, "~> 0.15.0", optional: true}` for Codex app-server, MCP,
  realtime, or voice helpers
- `{:gemini_cli_sdk, "~> 0.1.0", optional: true}` for Gemini-specific
  compatibility/runtime-kit surfaces above the shared core
- `{:amp_sdk, "~> 0.4.0", optional: true}` for Amp-specific
  compatibility/runtime-kit surfaces above the shared core

No extra ASM wiring is required for those optional deps. ASM always keeps the
common surface available through `cli_subprocess_core`, auto-detects optional
provider runtime availability, and activates only the provider-native
extension namespaces that genuinely exist today.

The published dependency cutover order is fixed for this stack:
`cli_subprocess_core` first, then the provider SDK packages, then
`agent_session_manager`.

## CLI Setup

Install provider CLIs you plan to use:

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @google/gemini-cli
npm install -g @openai/codex
npm install -g @sourcegraph/amp
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

## Runtime Architecture

Runtime execution path:

- `ASM.ProviderRegistry` resolves the provider onto `:core` or `:sdk`.
- `ASM.ProviderBackend.Core` runs `cli_subprocess_core` and is the required lane for `:remote_node`.
- `ASM.ProviderBackend.SDK` runs optional provider runtime kits when they are available locally.
- `ASM.Run.Server` starts the resolved backend, subscribes to backend events, wraps core events in `%ASM.Event{}`, and applies pipelines/reducers.
- `ASM.Session.Server` remains aggregate root for run admission, approval routing, and session-level cost accounting.

Lane selection is intentionally separate from execution mode:

- provider discovery chooses the preferred lane first
- execution mode then decides whether that preferred lane can execute as requested
- `:remote_node` always executes the core lane in the landed Phase 2A boundary

This produces three distinct values in observability metadata:

- `requested_lane`: the caller request (`:auto | :core | :sdk`)
- `preferred_lane`: the lane selected by provider/runtime discovery
- `lane`: the effective lane that actually executed

When `lane: :auto` prefers `:sdk` but `execution_mode: :remote_node`, ASM records `preferred_lane: :sdk` and executes with `lane: :core`, `backend: ASM.ProviderBackend.Core`, and `lane_fallback_reason: :sdk_remote_unsupported`. An explicit `lane: :sdk` with `execution_mode: :remote_node` is a configuration error.

See [Lane Selection](guides/lane-selection.md) for the full discovery and resolution flow.

## Lane Selection

Use `ASM.ProviderRegistry` to inspect lane availability and resolution:

```elixir
{:ok, provider_info} = ASM.ProviderRegistry.provider_info(:codex)
{:ok, lane_info} = ASM.ProviderRegistry.lane_info(:codex, lane: :auto)

{:ok, resolution} =
  ASM.ProviderRegistry.resolve(:codex,
    lane: :auto,
    execution_mode: :remote_node
  )
```

`provider_info/1` reports provider-level facts such as:

- `sdk_runtime`
- `sdk_available?`
- `available_lanes`
- `core_capabilities`
- `sdk_capabilities`

Those fields stay scoped to normalized lane/runtime discovery. Provider-native
extension inventory is reported separately through
`ASM.Extensions.ProviderSDK`.

`lane_info/2` is discovery-only and returns:

- `requested_lane`
- `preferred_lane`
- `backend` for that preferred lane
- `lane_reason`
- lane-specific `capabilities`

`resolve/2` adds execution-mode compatibility and returns the effective:

- `lane`
- `backend`
- `execution_mode`
- `lane_fallback_reason`

Typical projected metadata for a remote auto-lane run:

```elixir
%{
  requested_lane: :auto,
  preferred_lane: :sdk,
  lane: :core,
  backend: ASM.ProviderBackend.Core,
  execution_mode: :remote_node,
  lane_fallback_reason: :sdk_remote_unsupported
}
```

Lane rules:

- `:core` is always available
- `:sdk` is optional and requires the provider runtime kit to be installed and loadable
- `:auto` prefers `:sdk` when the runtime kit is available locally, otherwise it uses `:core`

## Provider Backend Model

`ASM.ProviderBackend.Core` is the baseline backend for every provider:

- required dependency surface
- works in `execution_mode: :local`
- works in `execution_mode: :remote_node`
- uses provider core profiles from `cli_subprocess_core`

`ASM.ProviderBackend.SDK` is additive, not foundational:

- selected only when the provider runtime kit is installed locally
- limited to `execution_mode: :local`
- keeps the same session/run/event model as the core lane
- remains optional so ASM still runs cleanly without SDK dependencies present

Approval routing, interrupt control, and result projection are lane-agnostic. The lane changes how the provider backend is started, not how the session aggregate behaves.

ASM intentionally stops at this normalized backend boundary. Rich
provider-native control families such as Claude hooks/permission callbacks and
Codex app-server remain in the provider SDK repos and stay out of ASM's core
execution model.

See [Provider Backends](guides/provider-backends.md) for the backend contract and lane responsibilities.

## Provider SDK Extensions

Phase 2B adds an explicit provider-native extension foundation above the
normalized kernel.

Use `ASM.Extensions.ProviderSDK` when you need to discover optional richer
provider-native seams without widening `ASM`, `ASM.Stream`, or
`ASM.ProviderRegistry`:

```elixir
alias ASM.Extensions.ProviderSDK

catalog = ProviderSDK.extensions()
active_extensions = ProviderSDK.available_extensions()
{:ok, claude_extension} = ProviderSDK.extension(:claude)
{:ok, codex_native_caps} = ProviderSDK.provider_capabilities(:codex)
{:ok, gemini_report} = ProviderSDK.provider_report(:gemini)

report = ProviderSDK.capability_report()

claude_extension.namespace
# ASM.Extensions.ProviderSDK.Claude

Enum.map(catalog, & &1.provider)
# [:claude, :codex]

Enum.map(active_extensions, & &1.provider)
# subset of [:claude, :codex], depending on installed optional deps

codex_native_caps
# [:app_server, :mcp, :realtime, :voice]

report.claude.sdk_available?
# true | false

gemini_report.namespaces
# []
```

Current built-in namespaces:

- `ASM.Extensions.ProviderSDK.Claude`
- `ASM.Extensions.ProviderSDK.Codex`

Optional-loading rules:

- `extensions/0` is the static native-extension catalog
- `available_extensions/0`, `provider_report/1`, and `capability_report/0`
  report the active composition state for the currently installed optional deps
- extension discovery is always safe to call
- `sdk_available?` reports whether the backing provider runtime kit is loadable
  locally
- rich provider-native APIs still live in `claude_agent_sdk` and `codex_sdk`
- ASM does not normalize those richer APIs into `ASM`, `ASM.Stream`, or
  `ASM.ProviderRegistry`
- Gemini and Amp may report `sdk_available?: true` while still exposing
  `namespaces: []` because they currently compose only through the common ASM
  surface and not through a separate provider-native extension namespace

The Claude namespace now exposes an explicit bridge into the SDK-local control
family:

```elixir
alias ASM.Extensions.ProviderSDK.Claude

asm_opts = [
  provider: :claude,
  cwd: File.cwd!(),
  permission_mode: :plan,
  model: "sonnet"
]

native_overrides = [
  enable_file_checkpointing: true,
  thinking: %{type: :adaptive}
]

{:ok, sdk_options} = Claude.sdk_options(asm_opts, native_overrides)

{:ok, client} =
  Claude.start_client(
    asm_opts,
    native_overrides,
    transport: MyApp.MockTransport
  )

:ok = ClaudeAgentSDK.Client.set_permission_mode(client, :plan)
```

That bridge is intentionally separate from the normalized kernel:

- ASM-style options stay in the first argument
- Claude-native options stay in `native_overrides`
- overlapping keys such as `:cwd`, `:permission_mode`, `:model`, and
  `:max_turns` are rejected and must stay in `asm_opts`
- control calls still use `ClaudeAgentSDK.Client.*`

The Codex namespace now exposes a narrow bridge into the SDK-local app-server
entry path:

```elixir
alias ASM.Extensions.ProviderSDK.Codex
alias Codex, as: CodexSDK

{:ok, conn} =
  Codex.connect_app_server(
    [
      provider: :codex,
      cli_path: "/usr/local/bin/codex",
      model: "gpt-5.4",
      reasoning_effort: :high
    ],
    [model_personality: :pragmatic],
    experimental_api: true
  )

{:ok, thread_opts} =
  Codex.thread_options(
    [
      provider: :codex,
      cwd: "/workspaces/repo",
      permission_mode: :auto,
      approval_timeout_ms: 45_000,
      output_schema: %{"type" => "object"}
    ],
    transport: {:app_server, conn},
    personality: :pragmatic
  )

{:ok, codex_opts} =
  Codex.codex_options(
    [provider: :codex, model: "gpt-5.4"],
    model_personality: :pragmatic
  )

{:ok, thread} = CodexSDK.start_thread(codex_opts, thread_opts)
```

That bridge is intentionally narrow:

- ASM-derived fields such as `:model`, `:reasoning_effort`, `:cwd`,
  `:approval_timeout_ms`, and `:output_schema` stay in ASM config
- Codex-native fields such as `:personality`, `:collaboration_mode`,
  `:attachments`, and app-server `transport` stay in `native_overrides`
- richer Codex APIs still live in `codex_sdk`
- app-server, MCP, realtime, and voice remain outside `ASM`, `ASM.Stream`, and
  `ASM.ProviderRegistry`

See [Provider SDK Extensions](guides/provider-sdk-extensions.md) for the
kernel-versus-extension split and the discovery API.

## Event Model And Result Projection

Backends emit core runtime events. `ASM.Run.Server` wraps them into `%ASM.Event{}` values that carry run/session scope plus stable observability metadata. Stream consumers therefore see the same lane and execution metadata that final results expose.

Common metadata keys include:

- `provider`
- `provider_display_name`
- `requested_lane`
- `preferred_lane`
- `lane`
- `backend`
- `execution_mode`
- `lane_reason`
- `lane_fallback_reason`
- `sdk_runtime`
- `sdk_available?`
- `capabilities`

`ASM.Stream.final_result/1` reduces the streamed `%ASM.Event{}` sequence through `ASM.Run.EventReducer` and projects a final `%ASM.Result{}`. `%ASM.Result.metadata` is therefore derived from the event stream rather than from a side channel, which keeps streaming and query-style consumption aligned.

See [Event Model And Result Projection](guides/event-model-and-result-projection.md) for the reducer and metadata projection details.

## Approval Routing And Interrupts

Approvals are session-scoped even though they originate from individual runs:

- a backend emits `:approval_requested`
- `ASM.Run.Server` notifies `ASM.Session.Server`
- the session indexes `approval_id` to the owning run process
- `ASM.approve/3` routes the decision back to that run

If an approval is not resolved before `approval_timeout_ms`, ASM emits `:approval_resolved` with `decision: :deny` and `reason: "timeout"`.

Interrupts are run-scoped:

- `ASM.interrupt/2` interrupts an active run through its backend and the run ends with a terminal `user_cancelled` error
- queued runs are removed from the session queue before they start

These control semantics stay the same across `:core` and `:sdk`, and across local versus remote execution.

See [Approvals And Interrupts](guides/approvals-and-interrupts.md) for the session/run control flow in more detail.

## Remote Node Execution

Remote execution is opt-in per session or per run. Local mode remains the default.

Session-level remote default:

```elixir
{:ok, session} =
  ASM.start_session(
    provider: :codex,
    execution_mode: :remote_node,
    # Remote backend options stay under :driver_opts
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
- `remote_boot_lease_timeout_ms` (accepted for config compatibility; retained in resolved execution config but not consumed by the current remote backend start path)
- `remote_bootstrap_mode` (`:require_prestarted` | `:ensure_started`, default `:require_prestarted`)
- `remote_cwd` (optional remote workspace override)
- `remote_transport_call_timeout_ms` (overrides `transport_call_timeout_ms` for remote backend control calls)

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

Lane and provider introspection:

- `ASM.ProviderRegistry.provider_info/1`
- `ASM.ProviderRegistry.lane_info/2`
- `ASM.ProviderRegistry.resolve/2`

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

## Execution Control Options

Session defaults and per-run overrides can also control execution behavior:

- `execution_mode` (`:local | :remote_node`)
- `lane` (`:auto | :core | :sdk`)
- `stream_timeout_ms` (maximum wait for the next run event; default `60000`)
- `queue_timeout_ms` (maximum time a queued run waits for capacity; default `:infinity`)
- `transport_call_timeout_ms` (backend control timeout used by the effective lane)
- `driver_opts` (remote execution settings bag for `:remote_node`)

## Provider Options

Common options:

- `provider`
- `permission_mode` (`:default | :auto | :bypass | :plan`)
- `cli_path`
- `cwd`
- `env`
- `approval_timeout_ms`
- `transport_timeout_ms` (lane runtime timeout forwarded to the effective core or SDK backend)
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
- [Lane Selection](guides/lane-selection.md)
- [Provider Backends](guides/provider-backends.md)
- [Provider SDK Extensions](guides/provider-sdk-extensions.md)
- [Event Model And Result Projection](guides/event-model-and-result-projection.md)
- [Approvals And Interrupts](guides/approvals-and-interrupts.md)
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
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix docs
mix hex.build
```
