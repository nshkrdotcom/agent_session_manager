<p align="center">
  <img src="assets/agent_session_manager.svg" alt="Agent Session Manager" width="200" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/agent_session_manager">
    <img src="https://img.shields.io/badge/github-nshkrdotcom%2Fagent__session__manager-24292e.svg" alt="GitHub" />
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" />
  </a>
</p>

# ASM (Agent Session Manager)

`ASM` is an OTP-native Elixir runtime for running multi-turn AI sessions across
five first-party CLI providers with one API.

Supported providers:

- Claude CLI
- Codex CLI (`exec` mode plus SDK app-server host tools when requested)
- Amp CLI
- Cursor Agent CLI
- Antigravity CLI

Antigravity is the current Google coding-agent SDK route. Gemini CLI and
`gemini_cli_sdk` remain retired. `gemini_ex` is a distinct model API SDK for
Gemini model endpoints; it is not an ASM CLI provider.

## Documentation Menu

- `README.md` - install, lanes, provider boundaries, and validation workflow
- `guides/execution-plane-alignment.md` - frozen lower-boundary packet and
  Wave 3 provisional lane note
- `guides/lane-selection.md` - lane discovery and execution fallback rules
- `guides/provider-backends.md` - core vs SDK backend responsibilities
- `guides/inference-endpoints.md` - `ASM.InferenceEndpoint` publication and endpoint contracts
- `guides/common-and-partial-provider-features.md` - normalized permission terms and partial common features such as Ollama
- `guides/event-model-and-result-projection.md` - stream projection and reducers
- `guides/migrating-to-0.12.md` - Core 0.4 and SDK-lane migration notes
- `examples/README.md` - live and offline proof entrypoints

## Why ASM

- One session/runtime model across providers.
- Shared core event vocabulary from `cli_subprocess_core`, wrapped in run/session-scoped `%ASM.Event{}` envelopes.
- Native Elixir streaming (`Enumerable`) with reducer-based result projections.
- Provider registry that resolves providers onto backend lanes instead of provider-specific command/parser ownership.
- Opaque managed-session identity that can be routed through a separately owned
  Runtime Client without exposing provider PIDs.
- Lower-boundary carriage aligned to the packet and Wave 5 durable session
  vocabulary without re-exporting raw
  `execution_plane/*` packages.

## Install

ASM 0.14.0 requires Elixir 1.19 or later.

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.14.0"}
  ]
end
```

For local workspace development, use the sibling repo as a `path:` dependency.

That dependency gives you ASM's normalized kernel plus discovery modules for
the built-in provider SDK extension namespaces. Those namespace modules are
always present in ASM, but they activate only when the matching optional
provider SDK dependency is installed.

Optional provider SDK dependencies stay additive. Add one only when you want
that provider's SDK lane/runtime kit or, where it exists today, its ASM
provider-native namespace:

- `{:claude_agent_sdk, "~> 0.19.0", optional: true}` for Claude control-protocol
  helpers and `ASM.Extensions.ProviderSDK.Claude`
- `{:codex_sdk, "~> 0.18.0", optional: true}` for Codex app-server, MCP,
  realtime, voice helpers, and `ASM.Extensions.ProviderSDK.Codex`
- `{:amp_sdk, "~> 0.7.0", optional: true}` for Amp SDK lane/runtime-kit
  availability and `ASM.Extensions.ProviderSDK.Amp`
- `{:antigravity_cli_sdk, "~> 0.2.0", optional: true}` for Antigravity SDK
  lane/runtime-kit availability. Antigravity currently composes through the
  common ASM provider surface and SDK runtime kit; it does not register a
  separate `ASM.Extensions.ProviderSDK.Antigravity` namespace.

Cursor follows the same dynamically discovered optional-SDK boundary, but the
published `cursor_cli_sdk 0.2.0` cannot be combined with Core 0.4 because it
requires Core `~> 0.3.0`. ASM 0.12 therefore keeps Cursor available through
the Core lane and does not declare or recommend a Cursor SDK dependency. The
SDK lane activates automatically when an independently installed,
Core-0.4-compatible Cursor SDK release is available.

Declaring the optional dependency is the only client-side activation step. No
extra ASM wiring is required. ASM always keeps the common surface available
through `cli_subprocess_core`, auto-detects optional provider runtime
availability, and activates only the provider-native extension namespaces
backed by the installed optional SDKs.

The package publication order for this stack remains `cli_subprocess_core`
first, then compatible provider SDK packages, then `agent_session_manager`.
Cursor is not a publication prerequisite for ASM.

## CLI Setup

Install provider CLIs you plan to use:

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
npm install -g @sourcegraph/amp
# Install Cursor Agent CLI using Cursor's current CLI documentation.
# Install the Antigravity CLI agent binary (`agy`) using its current CLI documentation.
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
- `CODEX_PATH`
- `AMP_CLI_PATH`
- `CURSOR_CLI_PATH`
- `ANTIGRAVITY_CLI_PATH`

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
{:ok, result} = ASM.query(:antigravity, "Say hello")
```

## CLI Inference Endpoint Publication

`ASM.InferenceEndpoint` publishes CLI-backed providers as endpoint-shaped
targets for northbound inference consumers.

The stable northbound API is:

- `ASM.InferenceEndpoint.consumer_manifest/0`
- `ASM.InferenceEndpoint.ensure_endpoint/3`
- `ASM.InferenceEndpoint.release_endpoint/1`

The endpoint publication set is published honestly from the landed endpoint
contract:

- Codex
- Claude
- Amp

Cursor and Antigravity are first-party ASM runtime providers, but the current
endpoint publication contract does not publish them through
`ASM.InferenceEndpoint`.

ASM derives `cli_completion_v1`, `cli_streaming_v1`, and `cli_agent_v2` from
the landed provider profiles and runtime tiers, but the endpoint path only
exposes completion and streaming. Tool-bearing or agent-loop-shaped requests
are rejected on that endpoint seam.

Amp remains common-surface-only for inference endpoint publication.
Cursor and Antigravity remain runtime providers outside this endpoint contract
until the endpoint seam is deliberately expanded and tested for those providers.
Cursor's SDK lane and Antigravity's SDK lane remain provider-native runtime
lanes, not endpoint contract expansions.
Cursor's provider SDK extension namespace is an explicit home for
provider-native settings. Antigravity currently has SDK runtime availability
without a separate provider SDK extension namespace. Neither widens the endpoint
contract. Amp, Cursor, and Antigravity explicitly report Codex-style
host dynamic tools and app-server control as unsupported, even when their SDK
runtime kits are installed.

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

The current `execution_surface` and `execution_environment` forms are the
family-facing mapped carrier IR around the frozen packet and Wave 5 durable
session vocabulary:

- `BoundarySessionDescriptor.v1`
- `ExecutionRoute.v1`
- `AttachGrant.v1`
- `CredentialHandleRef.v1`
- `ExecutionEvent.v1`
- `ExecutionOutcome.v1`
- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

The detailed minimal-lane interiors for the two intent contracts remain
provisional until Wave 3 prove-out. ASM names and carries that packet through
`ASM.Execution.Config.execution_plane_contracts/0`; it does not expose raw
Execution Plane package names as its public kernel API.
Boundary-backed metadata stays explicit under `metadata["boundary"]` with the
named subcontracts `descriptor`, `route`, `attach_grant`, `replay`,
`approval`, `callback`, and `identity`, published by
`ASM.Execution.Config.boundary_contract_keys/0`.
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
- `ASM.ProviderBackend.Core` runs `cli_subprocess_core` locally.
- `ASM.ProviderBackend.SDK` runs optional provider runtime kits when they are available locally.
- `ASM.Run.Server` starts the resolved backend, subscribes to backend events, wraps core events in `%ASM.Event{}`, and applies pipelines/reducers.
- `ASM.Session.Server` remains aggregate root for run admission, approval routing, and session-level cost accounting.

Lane selection produces three distinct values in observability metadata:

- `requested_lane`: the caller request (`:auto | :core | :sdk`)
- `preferred_lane`: the lane selected by provider/runtime discovery
- `lane`: the effective local lane that actually executed

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

- Claude, Codex, Cursor, and Antigravity SDK repos consume the shared
  mixed-input normalizer before backend execution
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
- `:allow_unknown_model` — when `true`, a Claude model id that is not in the
  shared registry is passed through to the CLI `--model` as-is (with a warning)
  instead of erroring. Use it to run a Claude model newer than the registry.
  Defaults to `false` (registered models only). This is a common provider
  option, not Claude-specific - every ASM-supported provider (`:codex`,
  `:amp`, `:antigravity`, `:cursor`) accepts the same flag with the
  same behavior, since model resolution flows through one shared
  ASM model-normalization path regardless of provider.

  Note the deliberate default divergence from `claude_agent_sdk`: the SDK is
  permissive by default (unknown model ids pass through with a warning),
  while ASM is strict by default. Same registry machinery, opposite
  defaults — ASM is a governed multi-provider manager, so unknown models
  require an explicit opt-in here. Do not "align" the two.

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
{:ok, resolution} = ASM.ProviderRegistry.resolve(:codex, lane: :auto)
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

`resolve/2` returns the effective local:

- `lane`
- `backend`
- `execution_mode`
- `lane_fallback_reason`

Typical projected metadata for an auto-lane run:

```elixir
%{
  requested_lane: :auto,
  preferred_lane: :sdk,
  lane: :sdk,
  backend: ASM.ProviderBackend.SDK,
  execution_mode: :local,
  lane_fallback_reason: nil
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
- uses provider core profiles from `cli_subprocess_core`

`ASM.ProviderBackend.SDK` is additive, not foundational:

- selected only when the provider runtime kit is installed locally
- limited to `execution_mode: :local`
- keeps the same session/run/event model as the core lane
- remains optional so ASM still runs cleanly without SDK dependencies present

Approval routing, interrupt control, and result projection are lane-agnostic. The lane changes how the provider backend is started, not how the session aggregate behaves.

Governed Codex runs must enter through runtime-auth evidence and a materialized
runtime produced by the verified materializer. `ASM.RuntimeAuth.CodexMaterialization`
accepts finalized provider defaults only when they do not carry live overrides,
then rejects provider-only calls, unmanaged ambient auth, and command, cwd, env,
config-root, auth-root, API-key, or base-URL smuggling before a Codex backend can
start. Default tests exercise this deterministically without live provider
credentials; live Codex smoke is separate from ASM CI.

Governed Claude and Amp starts are fail-closed in ASM until their
provider-auth materializers are available. Complete runtime-auth evidence is not
enough to reuse standalone CLI env, native login state, provider defaults,
command overrides, cwd overrides, session refs, target refs, or raw env maps as
governed authority. Those values remain standalone/example compatibility knobs
only.

Phase 14 governed handoff uses `ASM.RuntimeAuth.handoff_packet/2` and
`ASM.RuntimeAuth.accept_handoff/2`. The packet is ref-only and preserves
tenant, installation, authority, connector, provider account, credential
handle, credential lease, native-auth assertion, target, operation, trace, and
idempotency refs. Acceptance rejects revoked, rotated, unavailable, stale, or
raw-material handoffs before provider materialization.

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

report = ProviderSDK.capability_report()

claude_extension.namespace
# ASM.Extensions.ProviderSDK.Claude

Enum.map(catalog, & &1.provider)
# [:amp, :claude, :codex, :cursor]

Enum.map(active_extensions, & &1.provider)
# subset of [:amp, :claude, :codex, :cursor]

Enum.map(active_claude_extensions, & &1.namespace)
# [] or [ASM.Extensions.ProviderSDK.Claude]

codex_native_caps
# [:app_server, :mcp, :realtime, :voice]

report.claude.sdk_available?
# true | false

report.antigravity.sdk_available?
# true | false

report.antigravity.registered_namespaces
# []
```

Current built-in namespaces:

- `ASM.Extensions.ProviderSDK.Amp`
- `ASM.Extensions.ProviderSDK.Claude`
- `ASM.Extensions.ProviderSDK.Codex`
- `ASM.Extensions.ProviderSDK.Cursor`

Antigravity is intentionally absent from that native-extension namespace list.
It is still present in `ProviderSDK.capability_report/0` because ASM supports
Antigravity as a provider with core and optional SDK runtime lanes. Its report
has `registered_namespaces: []` until a real native-extension namespace is
added deliberately.

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
- rich provider-native APIs still live in the owning provider SDKs
- ASM does not normalize those richer APIs into `ASM`, `ASM.Stream`, or
  `ASM.ProviderRegistry`
- Amp and Cursor extension helpers start deliberately narrow. They
  derive only common placement/session data and require explicit
  `native_overrides` for Amp permissions/MCP/skills/thread behavior or Cursor mode/sandbox/MCP/plugin
  settings.
  Antigravity does not yet have an extension helper; direct SDK-lane execution
  uses `AntigravityCliSdk.Runtime.CLI`.

The Claude namespace now exposes an explicit bridge into the SDK-local control
family:

```elixir
alias ASM.Extensions.ProviderSDK.Claude

asm_opts = [
  provider: :claude,
  cwd: File.cwd!(),
  execution_environment: [permission_mode: :plan],
  model: "sonnet",
  reasoning_effort: :high
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
- overlapping keys such as `:cwd`, `:execution_environment`, `:model`,
  `:effort`, and `:max_turns` are rejected and must stay in `asm_opts`;
  callers select effort with ASM's `:reasoning_effort`
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
      model: "gpt-5.6-sol",
      reasoning_effort: :max
    ],
    [model_personality: :pragmatic],
    experimental_api: true
  )

{:ok, thread_opts} =
  Codex.thread_options(
    [
      provider: :codex,
      cwd: "/workspaces/repo",
      execution_environment: [permission_mode: :default],
      approval_timeout_ms: 45_000,
      output_schema: %{"type" => "object"}
    ],
    transport: {:app_server, conn},
    personality: :pragmatic
  )

{:ok, codex_opts} =
  Codex.codex_options(
    [provider: :codex, model: "gpt-5.6-sol"],
    model_personality: :pragmatic
  )

{:ok, thread} = CodexSDK.start_thread(codex_opts, thread_opts)
```

That bridge is intentionally narrow:

- ASM-derived fields such as `:model`, `:reasoning_effort`, `:cwd`,
  `:approval_timeout_ms`, and `:output_schema` stay in ASM config
- Codex-native thread fields such as `:personality`, `:collaboration_mode`,
  and `:attachments` stay in `native_overrides` for direct extension helpers
- richer Codex APIs still live in `codex_sdk`
- Codex app-server host dynamic tools are promoted through the SDK backend only
  when `app_server: true`, `host_tools: [...]`, or `dynamic_tools: [...]` is
  requested; MCP, realtime, voice, and broader app-server APIs remain in
  `codex_sdk`

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

ASM.ProviderFeatures.lane_manifest!(:codex, :sdk_app_server).capabilities.host_tools
# => %{support_state: :native, supported?: true, ...}

ASM.ProviderFeatures.require_capability(:amp, :sdk, :host_tools)
# => {:error, %ASM.Error{message: "... unsupported ..."}}
```

The current partial common feature is the ASM Ollama surface:

- Claude: supported
- Codex: supported
- Amp: unsupported

See [Common And Partial Provider Features](guides/common-and-partial-provider-features.md)
for the discovery API and the Claude-versus-Codex Ollama semantics.

Important boundary:

- `permission_mode` is ASM's normalized public execution knob
- provider-native flags such as Codex `:yolo`, Claude
  `:bypass_permissions`, or Amp
  `--dangerously-allow-all` are downstream renderings of that one normalized
  concept
- provider-specific knobs that are not part of ASM's normalized execution
  environment remain provider-specific
- Codex `:auto` / `:auto_edit` is intentionally not exposed through ASM's
  normalized `permission_mode`; use `:default`, `:bypass`, or direct
  `codex_sdk` thread options when you need Codex-native workspace-write
  behavior

Examples:

- Codex `ask_for_approval` is a `codex_sdk` thread option, not an ASM common
  execution-environment field
- `allowed_tools` is an ASM policy allowlist for observed provider tool-use
  events; it is not host-executable tool registration and does not admit
  common ASM host tools

So if a host is reasoning at the ASM layer:

- use `permission_mode` for the common approval/edit posture
- use `allowed_tools` only to constrain observed tool-use events when that
  policy layer is active
- use provider-native overrides only when the selected provider actually owns
  an additional concept outside the common ASM surface

Host-tool request, response, and declaration metadata reject secret-shaped
fields such as API-key, token, auth, credential, password, and bearer keys.
Provider tools must pass explicit policy-safe refs or redacted evidence instead
of raw credential material.

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

These control semantics stay the same across `:core` and `:sdk`.

See [Approvals And Interrupts](guides/approvals-and-interrupts.md) for the session/run control flow in more detail.

## Placement Boundary

ASM provider backends execute locally. Distributed admission and placement are
owned by the Execution Plane Runtime Client; ASM does not accept node names,
distribution cookies, or RPC placement options.

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

Result projections also include structured cost, terminal error, and any
provider-returned structured object:

- `%ASM.Result{cost: %{input_tokens: ..., output_tokens: ..., cost_usd: ...}}`
- `%ASM.Result{error: %ASM.Error{} | nil}`
- `%ASM.Result{object: term() | nil}` — the schema-conforming object for a run
  that requested one through `:output_schema`, and `nil` otherwise. Nothing
  reconstructs or guesses an object from prose.

## Execution Control Options

Session defaults and per-run overrides can also control execution behavior:

- `execution_mode` (`:local`)
- `lane` (`:auto | :core | :sdk`)
- `stream_timeout_ms` (maximum wait for the next run event; default `60000`)
- `queue_timeout_ms` (maximum time a queued run waits for capacity; default `:infinity`)
- `run_deadline_ms` (total wall-clock budget for one whole run; default
  `600000`, or `:infinity` to opt out)
- `transport_call_timeout_ms` (backend control timeout used by the effective lane)

`stream_timeout_ms` re-arms on every event, so it cannot end a run that keeps
talking without finishing. `run_deadline_ms` is armed once, when the backend
starts, and never re-arms: on expiry ASM closes the backend and its process
group and the run fails with `%ASM.Error{kind: :timeout, domain: :runtime}`.

## Session Ownership

`ASM.start_session/1` accepts `owner: pid`. An owned session is bound to that
process: when the owner goes down for any reason — including an untrappable
`Process.exit(owner, :kill)` — a supervised guard terminates the session
subtree and with it the provider process group.

The provider form of `ASM.query/3` is owner-scoped automatically, because it
starts a session the caller never sees:

```elixir
ASM.query(:claude, "Say hello", model: "sonnet")
```

Its ordinary teardown is an `after` block, which a killed caller never reaches.
The owner guard is what makes the one-shot contract hold anyway. Pass an
explicit `owner:` to bind the session to a different process, or start a
session without `owner:` when you want it to outlive its starter and manage it
with `ASM.stop_session/1`.

## Provider Options

Strict common options are intentionally narrow. Use
`ASM.Options.preflight(provider, opts)` to classify options before building new
generic ASM integrations. The strict classifier is pure validation: it does not
start sessions, spawn provider CLIs, or load optional SDK runtime modules.

Strict common/session options include:

- `model`
- `lane` (`:auto | :core | :sdk`)
- `execution_surface`
- `cli_path`
- `cwd`
- `approval_timeout_ms`
- `transport_timeout_ms` (lane runtime timeout forwarded to the effective core or SDK backend)
- `transport_headless_timeout_ms` (finite subprocess orphan-reap timeout;
  forwarded through Core and the Amp/Antigravity SDK lanes)
- queue/subscriber/run-capacity options used by ASM session scheduling

`ASM.query/3` takes the provider positionally:

```elixir
ASM.query(:antigravity, "Say hello", model: selected_model, lane: :core)
```

Here `selected_model` should come from the host application's explicit config
or request context, not hidden provider-specific environment reads inside ASM.

Do not pass `provider:` in `ASM.query/3` options. Redundant or mismatched
`provider:` options are rejected instead of being silently overwritten.

`lane: :core` does not probe or load optional provider SDK modules. An explicit
`lane: :sdk` without a loadable SDK runtime fails as
`%ASM.Error{kind: :config_invalid, domain: :config}` with
`%ASM.ProviderBackend.SdkUnavailableError{}` in `error.cause`.

Compatibility-only or provider-native options include:

- `permission_mode` and `provider_permission_mode`
- `env` and raw `args`
- provider-native system prompts, sandbox flags, tools, MCP, app-server, and
  backend-routing controls

Compatibility mode may still classify legacy callers, but these keys are not
part of the strict common ASM contract. Provider-native behavior belongs in the
owning SDK or in an explicit provider-native extension.

Provider-specific examples:

- Claude: `model`, `reasoning_effort`, `include_thinking`, `max_turns`
- Codex: `model`, `reasoning_effort`, `skip_git_repo_check`
- Amp: `model`, `mode`, `include_thinking`, `tools`

Partial common options are a third category: they are normalized ASM options
accepted by every provider schema, but gated on a per-provider capability, so
an unsupported provider fails with a typed capability error instead of quietly
ignoring the request.

- `output_schema` is gated on `:structured_output` (Claude and Codex today)
- the `ollama*` options are gated on `:ollama` (Claude and Codex today)
- `completion_only` is gated on `:completion_only` (Claude and Codex today).
  Every provider schema accepts the option shape so unsupported providers fail
  on the capability instead of reporting an unknown option.

See [Common And Partial Provider Features](guides/common-and-partial-provider-features.md).

Provider caveat:

- Codex rejects ASM `permission_mode: :auto` on the shared ingress because the
  current Codex workspace-write/auto-edit path creates a repo-local `.codex`
  artifact. Keep Codex on `:default` or `:bypass` in ASM, or drop down to
  direct `codex_sdk` thread options when you explicitly want that provider
  behavior.

## Live Examples

The repo examples are provider-agnostic and stay on the common ASM surface.
They only run when you explicitly choose a provider with `--provider`.

```bash
mix run --no-start examples/live_query.exs -- --provider claude
mix run --no-start examples/live_stream.exs -- --provider antigravity
mix run --no-start examples/live_session_lifecycle.exs -- --provider codex
./examples/run_all.sh --provider amp
./examples/run_all.sh --provider cursor
```

Environment knobs used by examples:

- `CLAUDE_CLI_PATH`, `CODEX_PATH`, `AMP_CLI_PATH`,
  `CURSOR_CLI_PATH`
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_CODEX_MODEL`, `ASM_AMP_MODEL`,
  `ASM_CURSOR_MODEL`

These knobs are read by examples and standalone compatibility helpers. They do
not satisfy governed runtime-auth, provider-account, target, session, handoff,
host-tool, or credential materialization authority.

If you omit `--provider`, the example prints a usage note and exits without running a live provider. See [examples/README.md](examples/README.md) for the full example set.
The promotion-path hub is [examples/promotion_path/README.md](examples/promotion_path/README.md).

## Guides

- [Boundary Enforcement](guides/boundary-enforcement.md)
- [Lane Selection](guides/lane-selection.md)
- [Provider Backends](guides/provider-backends.md)
- [Common And Partial Provider Features](guides/common-and-partial-provider-features.md)
- [Provider SDK Extensions](guides/provider-sdk-extensions.md)
- [Event Model And Result Projection](guides/event-model-and-result-projection.md)
- [Recovery Projection](guides/recovery-projection.md)
- [Approvals And Interrupts](guides/approvals-and-interrupts.md)
- [Live Adapter Feature Matrix](guides/live-adapters.md)

## Architecture Notes

Per-session subtree strategy uses `:rest_for_one`:

- `ASM.Run.Supervisor`
- `ASM.Session.Server`

Run workers are `restart: :temporary` to avoid restart loops after normal completion.

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
## Session Control And Recovery Handles

`agent_session_manager` now owns a first-class session-control seam instead of relying on provider-
specific escape hatches.

- `ASM.SessionControl` exposes shared list/resume/pause/intervene operations where the provider
  really supports them
- ASM session/run state now retains provider-native checkpoint data so upper callers can attempt an
  exact session resume before replaying work
- provider option validation now honestly reflects runtime support for recovery-related prompt
  controls: Claude and Codex accept supported prompt surfaces, while Amp rejects
  unsupported prompt controls such as `system_prompt` and `max_turns` instead of silently
  dropping them

This is the orchestration boundary that lets `prompt_runner_sdk` resume the same provider
conversation with `Continue` after a recoverable runtime failure.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
