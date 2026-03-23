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

These root modules are the namespace anchors for optional provider-native
helpers.

Claude now exposes an explicit bridge into the SDK-local control family:

- `ASM.Extensions.ProviderSDK.Claude.sdk_options/2`
- `ASM.Extensions.ProviderSDK.Claude.sdk_options_for_session/3`
- `ASM.Extensions.ProviderSDK.Claude.start_client/3`
- `ASM.Extensions.ProviderSDK.Claude.start_client_for_session/4`

Those helpers do not redefine Claude control semantics. They only:

- derive `ClaudeAgentSDK.Options` from ASM-style config or session defaults
- keep Claude-native options in a separate `native_overrides` bag
- start `ClaudeAgentSDK.Client` when callers explicitly opt into the SDK-local
  control family

Example:

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

{:ok, client} =
  Claude.start_client(
    asm_opts,
    native_overrides,
    transport: MyApp.MockTransport
  )

:ok = ClaudeAgentSDK.Client.set_permission_mode(client, :plan)
```

The normalized ASM APIs stay unchanged. Only the optional extension crosses
into the Claude-native client surface.

## Optional-Loading Rules

- discovery calls are always available from ASM
- each extension reports `sdk_available?`
- `sdk_available?` only means the backing SDK package is loadable locally
- richer provider-native APIs still live in the provider SDK repos
- ASM does not re-model those richer APIs in the kernel
- the Claude bridge keeps ASM config and Claude-native config in separate
  arguments on purpose

## Current Native Capability Inventory

Claude namespace:

- `:control_client`
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
