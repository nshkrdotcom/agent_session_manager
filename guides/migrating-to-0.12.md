# Migrating to 0.12

ASM 0.12 aligns the multi-provider runtime with `cli_subprocess_core 0.4.0`
and the Amp 0.7 / Antigravity 0.2 SDK train. Existing session and query entry
points remain compatible.

## Dependency Update

```elixir
{:agent_session_manager, "~> 0.12.0"}
```

Applications that declare the shared runtime directly must use:

```elixir
{:cli_subprocess_core, "~> 0.4.0"}
```

Optional SDK lanes use these prepared releases:

```elixir
{:amp_sdk, "~> 0.7.0", optional: true}
{:antigravity_cli_sdk, "~> 0.2.0", optional: true}
{:claude_agent_sdk, "~> 0.19.0", optional: true}
{:codex_sdk, "~> 0.18.0", optional: true}
```

Do not add `cursor_cli_sdk 0.2.0` to this dependency set: it requires
`cli_subprocess_core ~> 0.3.0` and cannot resolve alongside ASM 0.12's Core
0.4 requirement. Cursor remains fully available through ASM's Core lane. Its
SDK lane is dynamically discovered when a separately installed,
Core-0.4-compatible Cursor SDK release exists.

Publish Core 0.4 before publishing or resolving the SDK and ASM releases that
require it.

## Completion-Only Capability Gate

`:completion_only` is now a normalized option accepted structurally by all
five provider schemas and gated by Core's provider-feature manifest:

- Claude and Codex accept `completion_only: true` and retain their existing
  no-write/no-approval postures in both Core and SDK lanes.
- Amp, Antigravity, and Cursor reject the request with a typed
  `%ASM.Error{kind: :config_invalid}` naming the provider, option, and missing
  capability.
- `completion_only: false` remains valid for every provider.

Callers should match the typed ASM error instead of depending on an
`unknown options` validation message for unsupported providers.

## Headless Transport Timeout

ASM now forwards `transport_headless_timeout_ms` to Amp and Antigravity SDK
option structs as well as the Core lane. This is the finite bound used to reap
an orphaned transport. It is independent of the provider stream idle timeout
and ASM's non-rearming total run deadline.

The default remains 5 seconds. Keep it finite unless the deployment has a
separate, proven orphan-reaping boundary.

## Release Order

The prepared release train is:

1. `cli_subprocess_core` 0.4.0
2. provider SDK releases that require Core 0.4
3. `agent_session_manager` 0.12.0

Cursor is not a publication prerequisite for ASM.
