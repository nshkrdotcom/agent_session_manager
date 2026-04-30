# Common And Partial Provider Features

ASM exposes a single common session API across four providers, but not every
provider supports every feature.

`ASM.ProviderFeatures` is the public discovery surface for that reality.

It answers two questions:

- what provider-native term does ASM map a normalized permission mode onto?
- which ASM common features are available for this provider?
- which lane-specific capabilities are common, native, SDK-local,
  event-only, unsupported, or planned?

## Discover Provider Features

```elixir
iex> ASM.ProviderFeatures.manifest!(:codex)
%{
  provider: :codex,
  permission_modes: %{...},
  common_features: %{ollama: %{supported?: true, ...}},
  lanes: %{core: %{...}, sdk: %{...}, sdk_app_server: %{...}}
}
```

For one feature:

```elixir
iex> ASM.ProviderFeatures.common_feature!(:claude, :ollama)
%{
  supported?: true,
  common_surface: true,
  common_opts: [:ollama, :ollama_model, :ollama_base_url, :ollama_http, :ollama_timeout_ms],
  activation: %{provider_backend: :ollama},
  model_strategy: :canonical_or_direct_external,
  notes: [...]
}
```

## Lane Capability Manifests

`ASM.ProviderFeatures.lane_manifest!/2` exposes support states for capability
gating before a host starts a run.

Support states are:

- `:common` for normalized ASM support
- `:native` for a provider-native ASM lane
- `:sdk_local` for SDK behavior that is not promoted into ASM
- `:event_only` for observable provider events without a response API
- `:unsupported` for behavior callers must not request
- `:planned` for documented future work

Codex app-server host tools are native only on the promoted SDK app-server lane:

```elixir
iex> ASM.ProviderFeatures.lane_manifest!(:codex, :sdk_app_server).capabilities.host_tools.support_state
:native
```

Codex core exec can observe tool-use events, but it cannot answer app-server
dynamic tool requests:

```elixir
iex> ASM.ProviderFeatures.lane_manifest!(:codex, :core).capabilities.host_tools.support_state
:event_only
```

Amp and Gemini have explicit provider SDK extension namespaces, but they still
do not claim Codex app-server or host dynamic-tool semantics:

```elixir
iex> ASM.ProviderFeatures.require_capability(:gemini, :sdk, :host_tools)
{:error, %ASM.Error{}}
```

Claude reports native control capability separately. Claude hooks and
permission callbacks are not represented as Codex `dynamicTools` unless a real
request/response loop is implemented and tested.

`allowed_tools` remains an ASM execution-policy allowlist for observed
provider tool-use events. It is not host-executable tool registration, and it
does not change the host-tool admission decision: generic ASM `tools:`,
`host_tools:`, and `dynamic_tools:` remain rejected from strict common paths
until the all-four host-tool proof matrix is complete.

## Sandboxing And Placement

ASM does not expose a top-level all-provider sandbox switch. Execution
isolation and target placement are represented by `execution_surface`, including
surface kind, transport options, boundary class, and observability metadata.

Provider CLI sandbox flags remain provider-native. For example, Gemini's
`sandbox` flag and Codex's sandbox/app-server settings belong in the owning
provider SDK or explicit provider-native extension path. They are not the same
as Execution Plane isolation, and strict common ASM preflight rejects them.

## Permission Mode Compatibility

Historically ASM kept a public knob normalized as `:permission_mode`, then
mapped it to the provider-native form during validation. That behavior remains
available for compatibility, but new strict-common integrations should treat
permission controls as partial/provider-native until all-four safety semantics
are proven.

Examples:

- Claude `:bypass` -> `:bypass_permissions`
- Gemini `:bypass` -> `:yolo`
- Codex `:bypass` -> `:yolo`
- Amp `:bypass` -> `:dangerously_allow_all`

Codex exception:

- ASM does not accept normalized Codex `:auto` on the shared ingress
- the current Codex workspace-write/auto-edit path creates a repo-local
  `.codex` artifact
- use Codex `:default` or `:bypass` through ASM, or use `codex_sdk` directly
  when you explicitly want provider-native auto-edit behavior

This is only the compatibility normalized approval/edit posture.

It is not a promise that every provider exposes the same lower-level controls.
For example:

- Codex also has provider-specific thread options such as
  `ask_for_approval`
- Gemini also has a provider-native `sandbox` CLI flag
- those provider-specific knobs are not implied by ASM's common
  `:permission_mode`

`ASM.Options.preflight(provider, opts)` rejects permission aliases in strict
common mode. Compatibility mode classifies them separately from `common` and
returns structured warning metadata.

If you need to present the native term:

```elixir
iex> ASM.ProviderFeatures.permission_mode!(:amp, :dangerously_allow_all)
%{
  native_mode: :dangerously_allow_all,
  cli_args: ["--dangerously-allow-all"],
  cli_excerpt: "--dangerously-allow-all",
  label: "dangerously_allow_all"
}
```

## Common Ollama Surface

ASM now exposes a common Ollama surface:

- `:ollama`
- `:ollama_model`
- `:ollama_base_url`
- `:ollama_http`
- `:ollama_timeout_ms`

That surface is intentionally partial.

Supported today:

- Claude
- Codex

Not supported today:

- Gemini
- Amp

Unsupported providers fail validation immediately instead of silently ignoring
the common Ollama knobs.

### Claude Semantics

Claude's common Ollama path supports two model intents:

- keep a canonical Claude model name such as `haiku` and map it to an Ollama model id
- use a direct external model id as the selected model

ASM normalizes that into Claude's Ollama backend config and the core-owned
model payload.

### Codex Semantics

Codex's common Ollama path is a direct external model route.

ASM normalizes that into:

- `provider_backend: :oss`
- `oss_provider: "ollama"`

The selected model is the direct Ollama model id.

`ASM.ProviderFeatures.common_feature!(:codex, :ollama).compatibility` exposes
the default validated example model and the broader acceptance rule:

- `default_model: "gpt-oss:20b"`
- `acceptance: :runtime_validated_external_model`
- `validated_models: ["gpt-oss:20b"]`

That means ASM does not hard-block other installed local models such as
`llama3.2`. It forwards them through the shared Codex/Ollama route and leaves
the degraded-mode distinction to the upstream fallback-metadata behavior.

## Example Behavior

The ASM examples use these surfaces directly.

- common and provider-native examples default to `permission_mode: :bypass`
- startup output prints the provider-native permission term and CLI flag
- common prompt-based examples fail unless the provider returns the exact
  sentinel text they request
- `--ollama` and the related `--ollama-*` flags are only valid for Claude and Codex examples

## Practical Reading Guide

When you are trying to understand one of these knobs, ask which layer you are
standing in:

- ASM execution environment
  - strict common/runtime knobs such as `model`, `lane`,
    `execution_surface`, `cwd`, and runtime timeout or queue settings
  - compatibility-only knobs such as `permission_mode` while all-four safety
    semantics remain unproven
- ASM provider feature discovery
  - provider-native names and CLI spellings for compatibility or
    partial/discovery knobs
- provider SDK or provider CLI layer
  - extra provider-specific knobs that do not exist in ASM's common contract

Use `ASM.ProviderFeatures` when you need to present or gate these features in a
host application before starting a session.
