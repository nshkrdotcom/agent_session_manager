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

## Documentation Menu

- `README.md` - install, lanes, provider boundaries, and validation workflow
- `guides/lane-selection.md` - lane discovery and execution fallback rules
- `guides/provider-backends.md` - core vs SDK backend responsibilities
- `guides/inference-endpoints.md` - `ASM.InferenceEndpoint` publication and endpoint contracts
- `guides/common-and-partial-provider-features.md` - normalized permission terms and partial common features such as Ollama
- `guides/event-model-and-result-projection.md` - stream projection and reducers
- `guides/remote-node-execution.md` - remote execution model
- `examples/README.md` - live and offline proof entrypoints

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
    {:agent_session_manager, "~> 0.10.1"}
  ]
end
```

For local workspace development, replace that published requirement with the
repo-local `path:` override.

That dependency gives you ASM's normalized kernel plus the discovery modules
for the current built-in Claude/Codex extension namespaces. Those namespace
modules are always present in ASM, but they activate only when the matching
optional provider SDK dependency is installed.

Optional provider SDK dependencies stay additive. Add one only when you want
that provider's SDK lane/runtime kit or, where it exists today, its ASM
provider-native namespace:

- `{:claude_agent_sdk, "~> 0.16.0", optional: true}` for Claude control-protocol
  helpers and `ASM.Extensions.ProviderSDK.Claude`
- `{:codex_sdk, "~> 0.15.0", optional: true}` for Codex app-server, MCP,
  realtime, voice helpers, and `ASM.Extensions.ProviderSDK.Codex`
- `{:gemini_cli_sdk, "~> 0.1.0", optional: true}` for Gemini SDK lane/runtime-kit
  availability only; ASM does not expose a separate Gemini native extension
  namespace today
- `{:amp_sdk, "~> 0.4.0", optional: true}` for Amp SDK lane/runtime-kit
  availability only; ASM does not expose a separate Amp native extension
  namespace today

Declaring the optional dependency is the only client-side activation step. No
extra ASM wiring is required. ASM always keeps the common surface available
through `cli_subprocess_core`, auto-detects optional provider runtime
availability, and activates only the provider-native extension namespaces that
genuinely exist today.

The package publication order for this stack remains:
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

For Codex local OSS via Ollama, ASM forwards backend intent into the shared
core model registry instead of selecting a local model itself. Example:

```elixir
{:ok, session} =
  ASM.start_link(
    provider: :codex,
    provider_backend: :oss,
    oss_provider: "ollama",
    model: "llama3.2"
  )
```

`gpt-oss:20b` remains the default validated Codex/Ollama example model in the
shared stack, but ASM also accepts other installed local models such as
`llama3.2` and forwards them through the same route. In the example suite,
those broader local models should be treated as accepted but potentially
degraded upstream paths rather than guaranteed exact-output smoke targets.

ASM does not keep a second model-resolution layer above the shared core. Run
paths validate ASM/common-surface options first, then finalize provider opts
through `CliSubprocessCore.ModelInput.normalize/3` so backends consume an
attached `model_payload` instead of re-resolving model/backend intent locally.

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

## CLI Inference Endpoint Publication

`ASM.InferenceEndpoint` publishes CLI-backed providers as endpoint-shaped
targets for northbound inference consumers.

The stable northbound API is:

- `ASM.InferenceEndpoint.consumer_manifest/0`
- `ASM.InferenceEndpoint.ensure_endpoint/3`
- `ASM.InferenceEndpoint.release_endpoint/1`

The built-in CLI provider set is published honestly from the landed provider
profiles:

- Codex
- Claude
- Gemini
- Amp

ASM derives `cli_completion_v1`, `cli_streaming_v1`, and `cli_agent_v2` from
the landed provider profiles and runtime tiers, but the endpoint path only
exposes completion and streaming. Tool-bearing or agent-loop-shaped requests
are rejected on that endpoint seam.

Gemini and Amp remain common-surface-only providers. Their capability
publication can make them valid endpoint targets without introducing a second
ASM-native extension namespace.

See `guides/inference-endpoints.md` and
`examples/inference_endpoint_http.exs` for the published descriptor contract
and an offline endpoint proof.

## Session Model

`ASM` has three option layers:

- Session defaults: passed to `ASM.start_link/1` or `ASM.start_session/1`.
- Per-run overrides: passed to `ASM.stream/3` or `ASM.query/3`.
- Provider options: validated against provider schemas and handed to the resolved backend lane.

`Zoi` is now the canonical boundary-schema layer for new dynamic ASM boundary
work. `NimbleOptions` remains at the public keyword ingress during the
coexistence window, but schema-backed normalization now owns:

- provider-option envelope conformance after keyword validation
- `%ASM.Event{}` rebuild/serialization boundaries
- resolved remote-node execution payloads
- provider profile normalization

Per-run options override session defaults. Session defaults are inherited automatically.

## Generic Execution-Surface Carriage

ASM keeps the bridge-to-core contract transport-neutral.

Session defaults and per-run overrides carry transport placement separately
from runtime environment and approval context:

- `execution_surface`
- `execution_environment`

```elixir
execution_surface = [
  surface_kind: :ssh_exec,
  transport_options: [destination: "buildbox-a", port: 2222],
  target_id: "buildbox-a"
]

execution_environment = [
  workspace_root: "/repo",
  allowed_tools: ["git.status"],
  approval_posture: :manual,
  permission_mode: :default
]

{:ok, session} =
  ASM.start_session(
    provider: :codex,
    execution_surface: execution_surface,
    execution_environment: execution_environment
  )
```

Session startup normalizes stored defaults so `ASM.session_info/1` reflects the
same `CliSubprocessCore.ExecutionSurface` contract the downstream SDK repos
consume. `execution_environment` is normalized separately and carries
`workspace_root`, `allowed_tools`, `approval_posture`, and `permission_mode`.
Run execution then merges per-run overrides, enforces non-empty `allowed_tools`
in the ASM pipeline, and forwards placement only to the backend/runtime startup
path. `approval_posture: :none` stays explicit and runtime backends reject
unresolved starts instead of normalizing it away silently.

ASM keeps one public placement surface. `surface_kind`, `transport_options`,
`lease_ref`, `surface_ref`, `target_id`, `boundary_class`, and
`observability` belong inside `execution_surface`. Workspace and approval
policy do not.

Transport expansion stays core-owned. ASM carries the opaque placement contract
without branching on adapter modules or transport-family-specific path rules,
so future built-in surfaces should not require another ASM contract rewrite.
Boundary-backed external sessions can now arrive through that unchanged
transport-neutral surface as attach-ready `:guest_bridge` placement authored
above ASM. ASM does not inspect lower-boundary backend details; it only
consumes the normalized `execution_surface` contract.

Phase D now proves that unchanged execution config path over SSH as well:

- `:ssh_exec` executes through the generic `execution_surface` contract
- start, stream, interrupt, close, and terminal-error handling stay on the
  existing ASM surface
- guest bridge can remain transport-neutral at the ASM seam without turning ASM
  into a transport registry
- boundary-backed `:guest_bridge` sessions follow the same rule: descriptor
  validation and lower-boundary claim happen above ASM, while ASM only consumes
  the final `execution_surface`

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
- `:remote_node` always executes the core lane in the landed Phase 4 boundary

This produces three distinct values in observability metadata:

- `requested_lane`: the caller request (`:auto | :core | :sdk`)
- `preferred_lane`: the lane selected by provider/runtime discovery
- `lane`: the effective lane that actually executed

When `lane: :auto` prefers `:sdk` but `execution_mode: :remote_node`, ASM records `preferred_lane: :sdk` and executes with `lane: :core`, `backend: ASM.ProviderBackend.Core`, and `lane_fallback_reason: :sdk_remote_unsupported`. An explicit `lane: :sdk` with `execution_mode: :remote_node` is a configuration error.

See [Lane Selection](guides/lane-selection.md) for the full discovery and resolution flow.

## Centralized Model Selection

ASM does not own provider model policy.

The authoritative model-selection contract is provided by
`cli_subprocess_core`, and ASM consumes the resolved payload before dispatching
into provider adapters.

Authoritative core surface:

- `CliSubprocessCore.ModelRegistry.resolve/3`
- `CliSubprocessCore.ModelRegistry.validate/2`
- `CliSubprocessCore.ModelRegistry.default_model/2`
- `CliSubprocessCore.ModelRegistry.build_arg_payload/3`

ASM-side rules:

- option schemas remain value carriers
- provider backends and SDK extensions consume resolved payloads only
- missing provider path, missing SDK path, missing model, placeholder model
  input, and invalid reasoning effort remain hard failures
- ASM does not implement a second provider-specific fallback path

Provider-side alignment in the current stack is:

- Claude, Codex, and Gemini SDK repos consume the shared mixed-input normalizer
  before backend execution
- Amp exposes a payload-only model contract rather than a second raw model
  surface
- ASM always runs after that normalization boundary and passes finalized
  payloads into both the common core lane and optional SDK lanes

ASM-local schema ownership stops at orchestration boundaries. Provider-native
runtime schemas still stay in their owning SDK repos.

### Claude Ollama Backend Through ASM

Because ASM resolves Claude model payloads in core first, the Claude Ollama
path is configured through ASM provider opts and still flows through
`CliSubprocessCore.ModelRegistry`.

Relevant Claude provider opts:

- `:provider_backend`
- `:external_model_overrides`
- `:anthropic_base_url`
- `:anthropic_auth_token`
- `:model`

Example:

```elixir
{:ok, result} =
  ASM.query(:claude, "Reply with exactly: OK",
    provider_backend: :ollama,
    anthropic_base_url: "http://localhost:11434",
    external_model_overrides: %{"haiku" => "llama3.2"},
    model: "haiku"
  )
```

ASM does not build Ollama env itself. It forwards the Claude backend options to
core, attaches the resolved payload, and the downstream Claude lane consumes
that payload.

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

Phase 4 keeps an explicit provider-native extension foundation above the
normalized kernel.

Use `ASM.Extensions.ProviderSDK` when you need to discover optional richer
provider-native seams without widening `ASM`, `ASM.Stream`, or
`ASM.ProviderRegistry`:

```elixir
alias ASM.Extensions.ProviderSDK

catalog = ProviderSDK.extensions()
active_extensions = ProviderSDK.available_extensions()
{:ok, active_claude_extensions} = ProviderSDK.available_provider_extensions(:claude)
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

Enum.map(active_claude_extensions, & &1.namespace)
# [] or [ASM.Extensions.ProviderSDK.Claude]

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
- `provider_extensions/1` is the static native-extension catalog for one provider
- `available_extensions/0`, `provider_report/1`, and `capability_report/0`
  report the active composition state for the currently installed optional deps
- `available_provider_extensions/1` reports the active native-extension subset
  for one provider
- extension discovery is always safe to call
- `sdk_available?` reports whether the backing provider runtime kit is loadable
  locally
- `registered_namespaces` and `registered_extensions` keep the static catalog
  explicit even when `namespaces` and `extensions` are empty for the current
  dependency set
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
  execution_environment: [permission_mode: :plan],
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
- overlapping keys such as `:cwd`, `:execution_environment`, `:model`, and
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
      execution_environment: [permission_mode: :auto],
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

## Common And Partial Provider Features

ASM keeps the public approval knob normalized as `:permission_mode`, but the
provider-native terminology still matters for observability, examples, and host
application UX. `ASM.ProviderFeatures` is the public discovery surface for that
mapping and for ASM common features that are only supported by some providers.

```elixir
ASM.ProviderFeatures.permission_mode!(:codex, :yolo).cli_excerpt
# => "--dangerously-bypass-approvals-and-sandbox"

ASM.ProviderFeatures.common_feature!(:claude, :ollama)
# => %{supported?: true, activation: %{provider_backend: :ollama}, ...}
```

The current partial common feature is the ASM Ollama surface:

- Claude: supported
- Codex: supported
- Gemini: unsupported
- Amp: unsupported

See [Common And Partial Provider Features](guides/common-and-partial-provider-features.md)
for the discovery API and the Claude-versus-Codex Ollama semantics.

## Event Model And Result Projection

Backends emit core runtime events. `ASM.Run.Server` wraps them into `%ASM.Event{}` values that carry run/session scope plus stable observability metadata. Stream consumers therefore see the same lane and execution metadata that final results expose.

`%ASM.Event{}` remains the ergonomic runtime envelope, while `ASM.Schema.Event`
owns parsing and projection for persisted or rebuilt event maps. Forward-
compatible event maps preserve unknown keys on the struct's `:extra` field
instead of pushing ad hoc map traversal into callers.

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

The repo examples are provider-agnostic and stay on the common ASM surface.
They only run when you explicitly choose a provider with `--provider`.

```bash
mix run --no-start examples/live_query.exs -- --provider claude
mix run --no-start examples/live_stream.exs -- --provider gemini
mix run --no-start examples/live_session_lifecycle.exs -- --provider codex
./examples/run_all.sh --provider amp
```

Environment knobs used by examples:

- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH`, `AMP_CLI_PATH`
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL`, `ASM_AMP_MODEL`

If you omit `--provider`, the example prints a usage note and exits without running a live provider. See [examples/README.md](examples/README.md) for the full example set.

## Guides

- [Boundary Enforcement](guides/boundary-enforcement.md)
- [Lane Selection](guides/lane-selection.md)
- [Provider Backends](guides/provider-backends.md)
- [Common And Partial Provider Features](guides/common-and-partial-provider-features.md)
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

## Model Selection Contract

`/home/home/p/g/n/agent_session_manager` centralizes provider model resolution through `/home/home/p/g/n/cli_subprocess_core` before delegating to provider backends or SDK adapters. The authoritative policy APIs are `CliSubprocessCore.ModelRegistry.resolve/3`, `CliSubprocessCore.ModelRegistry.validate/2`, and `CliSubprocessCore.ModelRegistry.default_model/2`.

ASM option schemas are value carriers only. Backend lanes and provider extensions consume the resolved payload and do not own implicit provider/model fallback policy.
