# Provider SDK Extensions Guide

Phase 2B adds an explicit optional layer for provider-native surfaces above
ASM's normalized kernel.

## Kernel Versus Extension Split

Normalized kernel surfaces stay where they already belong:

- `ASM`
- `ASM.Stream`
- `ASM.Result`
- `ASM.ProviderRegistry`

Those APIs continue to own:

- provider selection
- lane selection
- normalized event/result projection
- session/run orchestration

Provider-native extension discovery now lives under
`ASM.Extensions.ProviderSDK`.

## Why This Is Separate

`ASM.ProviderRegistry` keeps normalized discovery on its existing surfaces:

- `provider_info/1`: `available_lanes`, `core_capabilities`, `sdk_capabilities`
- `lane_info/2`: `preferred_lane`, `backend`
- `resolve/2`: effective `lane`, `backend`

`ASM.Extensions.ProviderSDK` reports provider-native extension facts:

- explicit optional namespace modules
- provider-native capability inventory
- whether the backing SDK package is loadable locally

That keeps lane discovery and provider-native surface discovery from collapsing
into one API.

## Discovery API

```elixir
alias ASM.Extensions.ProviderSDK

ProviderSDK.extensions()

{:ok, claude_extension} = ProviderSDK.extension(:claude)
{:ok, codex_extensions} = ProviderSDK.provider_extensions(:codex)
{:ok, codex_native_caps} = ProviderSDK.provider_capabilities(:codex)

report = ProviderSDK.capability_report()
```

Current built-in namespaces:

- `ASM.Extensions.ProviderSDK.Claude`
- `ASM.Extensions.ProviderSDK.Codex`

These root modules are the namespace anchors for later optional helpers. In
this foundation slice they publish discovery metadata only.

## Optional-Loading Rules

- discovery calls are always available from ASM
- each extension reports `sdk_available?`
- `sdk_available?` only means the backing SDK package is loadable locally
- richer provider-native APIs still live in the provider SDK repos
- ASM does not re-model those richer APIs in the kernel

## Current Native Capability Inventory

Claude namespace:

- `:control_protocol`
- `:hooks`
- `:permission_callbacks`

Codex namespace:

- `:app_server`
- `:mcp`
- `:realtime`
- `:voice`

These are capability labels for discovery and documentation only in this
foundation slice. They are not new normalized kernel APIs.
