# Common And Partial Provider Features

ASM exposes a single common session API across five providers, but not every
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

Amp, Cursor, and Antigravity have SDK runtime lanes, but they still do
not claim Codex app-server or host dynamic-tool semantics:

```elixir
iex> ASM.ProviderFeatures.require_capability(:antigravity, :sdk, :host_tools)
{:error, %ASM.Error{}}
```

Claude reports native control capability separately. Claude hooks and
permission callbacks are not represented as Codex `dynamicTools` unless a real
request/response loop is implemented and tested.

`allowed_tools` remains an ASM execution-policy allowlist for observed
provider tool-use events. It is not host-executable tool registration, and it
does not change the host-tool admission decision: generic ASM `tools:`,
`host_tools:`, and `dynamic_tools:` remain rejected from strict common paths
until the all-provider host-tool proof matrix is complete.

## Sandboxing And Placement

ASM does not expose a top-level all-provider sandbox switch. Execution
isolation and target placement are represented by `execution_surface`, including
surface kind, transport options, boundary class, and observability metadata.

Provider CLI sandbox flags remain provider-native. For example, Cursor's
`sandbox` flag, Antigravity's `sandbox` flag, and
Codex's sandbox/app-server settings belong in the owning provider SDK or
explicit provider-native extension path. They are not the same as Execution
Plane isolation, and strict common ASM preflight rejects them.

## Permission Mode Mapping

ASM exposes one normalized public knob, `:permission_mode`, and maps it to the
provider-native form during validation. Strict-common integrations should treat
permission controls as partial/provider-native until all-provider safety
semantics are proven.

Examples:

- Claude `:bypass` -> `:bypass_permissions`
- Codex `:bypass` -> `:yolo`
- Amp `:bypass` -> `:dangerously_allow_all`
- Cursor `:bypass` -> `:bypass` -> `--force`
- Antigravity `:bypass` -> `:bypass` -> `--dangerously-skip-permissions`

Codex exception:

- ASM does not accept normalized Codex `:auto` on the shared ingress
- the current Codex workspace-write/auto-edit path creates a repo-local
  `.codex` artifact
- use Codex `:default` or `:bypass` through ASM, or use `codex_sdk` directly
  when you explicitly want provider-native auto-edit behavior

This is only the normalized approval/edit posture.

It is not a promise that every provider exposes the same lower-level controls.
For example:

- Codex also has provider-specific thread options such as
  `ask_for_approval`
- Cursor also has provider-native `mode`, `sandbox`, `approve_mcps`,
  worktree, plugin directory, and header flags
- Antigravity also has provider-native `sandbox`, `conversation`, `continue`,
  `add_dirs`, `print_timeout`, and `log_file` flags
- those provider-specific knobs are not implied by ASM's common
  `:permission_mode`

`ASM.Options.preflight(provider, opts)` rejects permission aliases in strict
common mode. Non-common permission aliases are classified separately from
`common` and return structured warning metadata.

If you need to present the native term:

```elixir
iex> ASM.ProviderFeatures.permission_mode!(:amp, :dangerously_allow_all)
%{
  native_mode: :dangerously_allow_all,
  cli_args: ["--dangerously-allow-all"],
  cli_excerpt: "--dangerously-allow-all",
  label: "dangerously_allow_all"
}

iex> ASM.ProviderFeatures.permission_mode!(:cursor, :bypass)
%{
  native_mode: :bypass,
  cli_args: ["--force"],
  cli_excerpt: "--force",
  label: "force"
}

iex> ASM.ProviderFeatures.permission_mode!(:antigravity, :bypass)
%{
  native_mode: :bypass,
  cli_args: ["--dangerously-skip-permissions"],
  cli_excerpt: "--dangerously-skip-permissions",
  label: "dangerously-skip-permissions"
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

- Cursor
- Amp
- Antigravity

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

## Structured Output

`structured_output` is a partial provider feature, discovered the same way as
the Ollama surface:

```elixir
iex> ASM.ProviderFeatures.common_feature!(:claude, :structured_output)
%{
  supported?: true,
  common_surface: true,
  common_opts: [:output_schema],
  activation: %{option: :output_schema},
  compatibility: %{wire_form: :inline_json, cli_flag: "--json-schema"},
  notes: [...]
}

iex> ASM.ProviderFeatures.supports_common_feature?(:cursor, :structured_output)
false
```

The ASM-facing option is `:output_schema`, a JSON Schema map.

Supported today:

- Claude
- Codex

Not supported today:

- Cursor
- Amp
- Antigravity

The two supported providers do not agree on how the schema reaches the CLI,
and that asymmetry is a provider fact rather than an ASM choice:

| Provider | `compatibility.wire_form` | CLI flag         | How the schema travels        |
| -------- | ------------------------- | ---------------- | ----------------------------- |
| Claude   | `:inline_json`            | `--json-schema`  | inline JSON on argv           |
| Codex    | `:file_path`              | `--output-schema` | a temporary file, path on argv |

`codex exec` types `--output-schema` as a path and exits non-zero when it
cannot read the file, so materializing the schema on disk is not a degraded
mode — it is the only working mode. Both ASM lanes do it: the `:core` lane
through the shared provider profile, and the `:sdk` lane through
`CliSubprocessCore.OutputSchemaFile`, whose file is owned by the run process
and removed when the run ends by any route, including an untrappable kill.

An unsupported provider fails validation with a typed `%ASM.Error{}` naming the
provider, the option, and the missing capability. It never silently drops the
schema and returns unconstrained prose:

```elixir
iex> ASM.query(:cursor, "Summarize", output_schema: %{"type" => "object"})
{:error, %ASM.Error{kind: :config_invalid, domain: :config}}
```

A schema-conforming reply is projected onto `ASM.Result.object` (and
`ASM.Message.Result.object` on the terminal message). It is `nil` when the
provider returned no structured object; nothing reconstructs or guesses an
object from prose.

### Where This Boundary Sits

`codex_sdk/AGENTS.md` states that output schemas belong in that SDK, and this
guide does not contradict it. The split is:

- ASM owns the **capability vocabulary** (`:structured_output`, its per-provider
  support state and wire form) and the **normalized option** (`:output_schema`),
  because a caller choosing between providers needs to ask one question in one
  place.
- `cli_subprocess_core` owns the **flag spelling and materialization**
  (`--json-schema` inline versus `--output-schema` on disk).
- `codex_sdk` keeps every richer Codex-native structured-output control.

ASM holds no second catalog of provider capabilities. Every entry in
`ASM.ProviderFeatures` comes from `CliSubprocessCore.ProviderFeatures`; a
provider the shared catalog does not describe is reported as unsupported rather
than omitted, so callers can still query it.

## Completion-Only Invocations

`completion_only: true` asks a provider for a completion, not a coding agent.
It is available for Claude and Codex, the two providers whose CLIs have a
real no-write, no-approval posture, and it **replaces** any caller-supplied
permission mode rather than merging with it:

| Provider | Effect                                                             |
| -------- | ------------------------------------------------------------------ |
| Claude   | empty tool set, no settings sources, strict MCP config, plan mode  |
| Codex    | read-only, ephemeral, no ambient config/rules/search/skills, never approvals |

Both ASM lanes carry it. The `:core` lane passes the option to the shared
provider profile; the `:sdk` lane re-expresses the same posture in each SDK's
own vocabulary (`sandbox: :read_only`, `ephemeral: true`,
`ignore_user_config: true`, `ignore_rules: true`, disabled web search and
skills, and `ask_for_approval: :never` for Codex thread options;
`tools: []`, `setting_sources: []`, `strict_mcp_config: true`
and `permission_mode: :plan` for Claude SDK options), because the SDK lane
derives its own options and would otherwise discard the request silently.

Providers without that posture reject `:completion_only` instead of accepting
and ignoring it.

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
  - normalized permission knobs such as `permission_mode` while all-provider
    safety semantics remain partial
- ASM provider feature discovery
  - provider-native names and CLI spellings for partial/discovery knobs
- provider SDK or provider CLI layer
  - extra provider-specific knobs that do not exist in ASM's common contract

Use `ASM.ProviderFeatures` when you need to present or gate these features in a
host application before starting a session.
