# Lane Selection Guide

`ASM` discovers and resolves a local provider backend lane.

## The Three Lane Values

- `requested_lane`: what the caller asked for (`:auto | :core | :sdk`)
- `preferred_lane`: what provider/runtime discovery selected
- `lane`: the backend lane that actually executed

## Lane Policies

- `:core` always resolves to `ASM.ProviderBackend.Core` and does not probe or
  load optional provider SDK runtime modules
- `:sdk` resolves to `ASM.ProviderBackend.SDK` only when the provider runtime kit is installed locally
- `:auto` prefers `:sdk` when that runtime kit is available locally, otherwise it uses `:core`

An explicit `lane: :sdk` without a loadable SDK runtime fails as a config error
whose `cause` is `%ASM.ProviderBackend.SdkUnavailableError{}`. It never falls
back to the core backend. `lane: :auto` is the only lane that may fall back to
core for SDK absence.

Use `ASM.ProviderRegistry.provider_info/1` when you want provider-level facts,
`lane_info/2` when you want discovery without selecting an effective backend, and
`resolve/2` when you need the effective backend choice for a real run.

`lane_info(provider, lane: :core)` intentionally does not check SDK
availability. Use `provider_info/1` when you explicitly need provider SDK
availability discovery.

## Local Execution

Lane selection is discovery-driven:

- local runs can execute either `:core` or `:sdk`
- local `:core` and local `:sdk` preserve the same normalized
  `execution_surface` contract
- admitted distributed placement belongs to the Execution Plane Runtime Client,
  not to provider lane selection

## Observability Fields

Lane resolution is projected into both streamed `%ASM.Event{}` metadata and the
final `%ASM.Result.metadata` map.

Common fields:

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

That shared metadata keeps stream consumers and one-shot query consumers in
sync about which runtime path actually executed.
