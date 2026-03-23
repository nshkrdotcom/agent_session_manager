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
- never becomes a required dependency for ASM itself
- may exist without any separate ASM provider-native namespace, as with Gemini
  and Amp today

## Common Contract

Both backends satisfy the same `ASM.ProviderBackend` behaviour:

```elixir
@callback start_run(map()) :: {:ok, pid(), term()} | {:error, term()}
@callback send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
@callback end_input(pid()) :: :ok | {:error, term()}
@callback interrupt(pid()) :: :ok | {:error, term()}
@callback close(pid()) :: :ok
@callback subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
@callback info(pid()) :: map()
```

That keeps `ASM.Run.Server` lane-agnostic after resolution.

## Backend Selection

`ASM.ProviderRegistry.resolve/2` chooses which backend module to use.

- `lane: :core` resolves to `ASM.ProviderBackend.Core`
- `lane: :sdk` resolves to `ASM.ProviderBackend.SDK` only when the runtime kit is available locally
- `lane: :auto` prefers the SDK lane when available and otherwise falls back to the core lane

`execution_mode` is applied after lane discovery. In the landed Phase 2A
boundary, remote execution always uses the core backend even if `:auto`
preferred `:sdk`.

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
