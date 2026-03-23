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

## Dependency Model

ASM keeps `cli_subprocess_core` required and all provider SDK packages
optional.

- depending only on `:agent_session_manager` gives you the common ASM surface
- adding `:claude_agent_sdk` or `:codex_sdk` activates the matching SDK lane
  and the matching provider-native namespace when it is loadable locally
- adding `:gemini_cli_sdk` or `:amp_sdk` activates only SDK lane/runtime-kit
  availability today; Gemini and Amp still have no separate ASM native
  namespace
- declaring the optional dependency is the only client-app activation step;
  ASM performs discovery and activation automatically

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
ProviderSDK.available_extensions()

{:ok, claude_extension} = ProviderSDK.extension(:claude)
{:ok, active_claude_extensions} = ProviderSDK.available_provider_extensions(:claude)
{:ok, codex_extensions} = ProviderSDK.provider_extensions(:codex)
{:ok, codex_native_caps} = ProviderSDK.provider_capabilities(:codex)
{:ok, gemini_report} = ProviderSDK.provider_report(:gemini)

report = ProviderSDK.capability_report()
```

Current built-in namespaces:

- `ASM.Extensions.ProviderSDK.Claude`
- `ASM.Extensions.ProviderSDK.Codex`

These root modules are the namespace anchors for optional provider-native
helpers.

Activation-aware discovery follows a separate rule:

- `extensions/0` is the static Claude/Codex native-extension catalog
- `provider_extensions/1` is the static native-extension catalog for one
  provider
- `available_extensions/0` reports which of those namespaces are active for the
  currently installed optional deps
- `available_provider_extensions/1` reports the active native-extension subset
  for one provider
- `provider_report/1` and `capability_report/0` always include all ASM
  providers, including Gemini and Amp, and show whether each provider SDK
  runtime is available plus any active native namespace inventory
- `registered_namespaces` and `registered_extensions` keep the static catalog
  visible even when a provider currently composes only through the common
  surface
- Gemini and Amp may therefore report `sdk_available?: true` with
  `namespaces: []`, because they currently compose only through the common ASM
  surface

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

Codex now exposes a similarly narrow bridge into the SDK-local app-server
entry path:

- `ASM.Extensions.ProviderSDK.Codex.codex_options/2`
- `ASM.Extensions.ProviderSDK.Codex.codex_options_for_session/3`
- `ASM.Extensions.ProviderSDK.Codex.thread_options/2`
- `ASM.Extensions.ProviderSDK.Codex.thread_options_for_session/3`
- `ASM.Extensions.ProviderSDK.Codex.connect_app_server/3`
- `ASM.Extensions.ProviderSDK.Codex.connect_app_server_for_session/4`

Those helpers do not re-model app-server, MCP, realtime, or voice as ASM
kernel APIs. They only:

- derive `Codex.Options` from ASM-style config or session defaults
- derive `Codex.Thread.Options` from ASM-style config or session defaults
- keep Codex-native global or thread-only fields in explicit override bags
- start `Codex.AppServer` when callers explicitly opt into the SDK-local
  app-server family

Example:

```elixir
alias ASM.Extensions.ProviderSDK.Codex
alias Codex, as: CodexSDK

{:ok, conn} =
  Codex.connect_app_server(
    [provider: :codex, model: "gpt-5.4", reasoning_effort: :high],
    [model_personality: :pragmatic],
    experimental_api: true
  )

{:ok, thread_opts} =
  Codex.thread_options(
    [
      provider: :codex,
      cwd: "/repo",
      permission_mode: :auto,
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

## Optional-Loading Rules

- discovery calls are always available from ASM
- each extension reports `sdk_available?`
- `sdk_available?` only means the backing SDK package is loadable locally
- `provider_capabilities/1` reports only active native capabilities for the
  current dependency set
- richer provider-native APIs still live in the provider SDK repos
- ASM does not re-model those richer APIs in the kernel
- the Claude bridge keeps ASM config and Claude-native config in separate
  arguments on purpose
- ASM-derived fields such as `:cwd`, `:permission_mode`, `:model`,
  `:max_turns`, and `:timeout_ms` must stay in ASM config and are rejected from
  `native_overrides`
- the Codex bridge follows the same rule for ASM-derived fields such as
  `:model`, `:reasoning_effort`, `:cwd`, `:approval_timeout_ms`, and
  `:output_schema`
- the Codex bridge is intentionally useful only at the app-server entry seam;
  the actual app-server, MCP, realtime, and voice APIs remain in `codex_sdk`

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
