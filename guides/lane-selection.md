# Lane Selection Guide

`ASM` separates lane discovery from execution mode. Provider resolution decides
which backend lane is preferred, and only then does execution mode decide
whether that lane can actually run.

## The Three Lane Values

- `requested_lane`: what the caller asked for (`:auto | :core | :sdk`)
- `preferred_lane`: what provider/runtime discovery selected before execution-mode checks
- `lane`: the backend lane that actually executed

This distinction matters most when `execution_mode: :remote_node` is involved.

## Lane Policies

- `:core` always resolves to `ASM.ProviderBackend.Core`
- `:sdk` resolves to `ASM.ProviderBackend.SDK` only when the provider runtime kit is installed locally
- `:auto` prefers `:sdk` when that runtime kit is available locally, otherwise it uses `:core`

Use `ASM.ProviderRegistry.provider_info/1` when you want provider-level facts,
`lane_info/2` when you want discovery without execution-mode compatibility, and
`resolve/2` when you need the effective backend choice for a real run.

## Local Versus Remote Execution

Lane selection remains discovery-driven in both modes:

- local runs can execute either `:core` or `:sdk`
- remote runs execute only the core lane in Phase 1
- `lane: :sdk` with `execution_mode: :remote_node` is a configuration error
- `lane: :auto` may still report `preferred_lane: :sdk` but execute with `lane: :core`

Typical remote auto-lane resolution:

```elixir
{:ok, resolution} =
  ASM.ProviderRegistry.resolve(:codex,
    lane: :auto,
    execution_mode: :remote_node
  )

resolution.observability
# %{
#   requested_lane: :auto,
#   preferred_lane: :sdk,
#   lane: :core,
#   backend: ASM.ProviderBackend.Core,
#   execution_mode: :remote_node,
#   lane_fallback_reason: :sdk_remote_unsupported,
#   ...
# }
```

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
