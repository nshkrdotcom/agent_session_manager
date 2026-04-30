# Provider Backends Guide

ASM runs providers through a small backend contract instead of provider-specific
driver/parser stacks.

## Backend Roles

`ASM.ProviderBackend.Core` is the required baseline backend:

- starts `CliSubprocessCore.Session`
- works in `execution_mode: :local`
- works in `execution_mode: :remote_node`
- uses the built-in provider profiles from `cli_subprocess_core`

`ASM.ProviderBackend.SDK` is optional and additive:

- starts provider runtime kits when they are installed locally
- works only in `execution_mode: :local`
- preserves the same session/run/event model as the core backend
- preserves the same normalized execution-surface contract as the core backend
  for local subprocess and SSH lanes
- never becomes a required dependency for ASM itself
- may exist without any separate ASM provider-native namespace, as with Gemini
  and Amp today
- promotes the Codex app-server host-tool lane when Codex provider options
  request `app_server: true`, `host_tools: [...]`, or `dynamic_tools: [...]`

## Common Contract

Both backends satisfy the same `ASM.ProviderBackend` behaviour:

```elixir
@callback start_run(map()) :: {:ok, pid(), ASM.ProviderBackend.Info.t()} | {:error, term()}
@callback send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
@callback end_input(pid()) :: :ok | {:error, term()}
@callback interrupt(pid()) :: :ok | {:error, term()}
@callback close(pid()) :: :ok
@callback subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
@callback info(pid()) :: ASM.ProviderBackend.Info.t()
```

That keeps `ASM.Run.Server` lane-agnostic after resolution.

After `subscribe/3`, the kernel receives `%ASM.ProviderBackend.Event{}` messages
instead of matching provider or transport mailbox tags directly. The envelope
can carry either a normalized `CliSubprocessCore.Event` or an ASM-native event
such as `:host_tool_requested` from the Codex app-server lane.

`ASM.ProviderBackend.Info` is the ASM-owned metadata contract consumed by the
kernel:

- `provider`
- `lane`
- `backend`
- `runtime`
- `capabilities`
- `session`
- `observability`

The `session` field may still contain backend/runtime details, but backend
adapters must strip raw delivery tags such as `session_event_tag` before that
data crosses into ASM kernel state.

## Backend Selection

`ASM.ProviderRegistry.resolve/2` chooses which backend module to use.

- `lane: :core` resolves to `ASM.ProviderBackend.Core` without probing or
  loading optional provider SDK modules
- `lane: :sdk` resolves to `ASM.ProviderBackend.SDK` only when the runtime kit is available locally
- `lane: :auto` prefers the SDK lane when available and otherwise falls back to the core lane

An explicit `lane: :sdk` must fail clearly when the SDK runtime kit is
unavailable. It must not silently fall back to the core lane. Fallback is only
valid for documented `lane: :auto` cases.

The public error remains `%ASM.Error{kind: :config_invalid, domain: :config}`,
with `%ASM.ProviderBackend.SdkUnavailableError{}` in `error.cause` for the
SDK-unavailable category. Tests and callers should assert that category instead
of matching human-readable error text.

`execution_mode` is applied after lane discovery. In the landed Phase 3
boundary, remote execution always uses the core backend even if `:auto`
preferred `:sdk`.

That split is intentional:

- local `:core` and local `:sdk` both preserve the same normalized
  `execution_surface` contract and its `ExecutionSurface` metadata
- `:remote_node` remains a separate ASM execution mode, not another execution
  surface

## Observability

Backend choice is visible in run/event metadata:

- `requested_lane`
- `preferred_lane`
- `lane`
- `backend`
- `execution_mode`
- `lane_reason`
- `lane_fallback_reason`

That metadata is merged into both streamed `%ASM.Event{}` values and the final
`%ASM.Result.metadata` projection.

## Provider-Native Extensions Stay Above The Backend Boundary

`ASM.ProviderRegistry` and the backend modules stop at normalized lane/runtime
selection.

Provider-native capability reporting now lives under
`ASM.Extensions.ProviderSDK`:

- `ASM.Extensions.ProviderSDK.extension/1`
- `ASM.Extensions.ProviderSDK.provider_extensions/1`
- `ASM.Extensions.ProviderSDK.available_provider_extensions/1`
- `ASM.Extensions.ProviderSDK.provider_capabilities/1`
- `ASM.Extensions.ProviderSDK.capability_report/0`

That keeps backend discovery focused on `:core` versus `:sdk`, while
provider-native surfaces such as Claude control semantics and Codex app-server,
MCP, realtime, and voice remain explicit optional seams above the kernel.

Gemini and Amp still affect backend lane availability through their optional
runtime kits, but they do not add separate ASM provider-native namespaces in
the current catalog.

For Claude specifically, `ASM.Extensions.ProviderSDK.Claude` can bridge ASM
config into `ClaudeAgentSDK.Client`, but the resulting control calls still live
on `ClaudeAgentSDK.Client.*` rather than the backend contract.

## Codex App-Server Host Tools

Codex remains on the normal SDK exec runtime unless app-server is requested.
The app-server path:

- starts `Codex.AppServer` with `experimental_api: true`
- converts `ASM.HostTool.Spec` values into Codex `dynamicTools`
- starts or resumes a Codex thread using the app-server transport
- maps `DynamicToolCallRequested` to `:host_tool_requested`
- executes registered run `tools` automatically when present
- responds with `Codex.AppServer.respond/3`
- emits `:host_tool_completed`, `:host_tool_failed`, or `:host_tool_denied`

The app-server backend still reports through the same `ASM.ProviderBackend`
contract and emits normal core assistant/result events for stream consumers.
Broader Codex app-server APIs such as MCP, realtime, voice, plugin, and
filesystem helpers remain in `codex_sdk` or the provider SDK extension seam.

This is Codex-native behavior, not proof of all-provider ASM host-tool support.
Generic ASM `tools:` must remain rejected or provider-native until the all-four
host-tool admission checklist is complete.

## Claude Backend-Specific Model Inputs

Claude is the first backend where ASM now forwards backend-specific model
inputs into the shared core model registry.

The relevant Claude provider fields are:

- `:provider_backend`
- `:external_model_overrides`
- `:anthropic_base_url`
- `:anthropic_auth_token`
- `:model`

Those values are still treated as value carriers only.

ASM does not validate Ollama models itself and does not build Ollama CLI env
itself. It forwards those values to
`CliSubprocessCore.ModelRegistry.build_arg_payload/3`, then passes the resolved
payload to either the core Claude profile or `ClaudeAgentSDK.Options`.

## Codex Backend-Specific Model Inputs

Codex now follows the same pattern for backend-aware model resolution.

Relevant Codex provider fields:

- `:provider_backend`
- `:model_provider`
- `:oss_provider`
- `:ollama_base_url`
- `:ollama_http`
- `:ollama_timeout_ms`
- `:model`
- `:reasoning_effort`

For the current local Ollama path, ASM callers should use:

- `provider_backend: :oss`
- `oss_provider: "ollama"`
- `model: "<local model id>"`

ASM still does not invent Codex backend flags locally. It forwards those inputs to
`CliSubprocessCore.ModelInput.normalize/3`, which in turn resolves through
`CliSubprocessCore.ModelRegistry.build_arg_payload/3` when the caller supplied
raw knobs instead of a payload. ASM then passes the finalized payload into
either the core Codex profile or `Codex.Options` / `Codex.Thread.Options` on
the SDK lane.

For Codex/Ollama, the shared core keeps `gpt-oss:20b` as the default validated
example model, but it also accepts other installed local model ids such as
`llama3.2`. The degraded-mode distinction for those non-default models is
metadata-driven rather than a hard rejection in ASM.

If a custom `ollama_base_url` is supplied, the finalized payload carries it in
payload-owned runtime data (`CODEX_OSS_BASE_URL`). Raw Ollama roots are
normalized to the OpenAI-compatible `/v1` base for Codex, so downstream core
and SDK transports can consume the payload alone after normalization.

## Gemini Backend-Specific Model Inputs

Gemini has a narrower surface than Claude or Codex.

Relevant Gemini provider fields:

- `:model`

The shared model registry currently accepts Gemini CLI virtual model ids such
as `auto-gemini-3` and `auto-gemini-2.5`, CLI aliases such as `pro`, `flash`,
and `flash-lite`, and concrete Gemini ids such as
`gemini-3.1-flash-lite-preview`.

When ASM bridges into `gemini_cli_sdk`, the Gemini SDK now consumes the shared
normalized payload instead of re-resolving over an explicit payload. Repo-local
`GEMINI_MODEL` defaults remain fallback inputs only when the caller did not
supply a payload.

## Amp Backend-Specific Model Inputs

Amp is intentionally payload-only for model input in the current stack.

Relevant Amp provider fields:

- `:model_payload` only

`amp_sdk` does not expose a second raw model/backend surface. ASM finalizes any
shared-core model selection before the Amp SDK boundary, and `AmpSdk.Types.Options.validate!/1`
only canonicalizes a supplied payload rather than inventing another resolution
path inside the Amp repo.
