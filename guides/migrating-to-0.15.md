# Migrating to 0.15

ASM 0.15 keeps its narrow runtime boundary on `cli_subprocess_core ~> 0.7.0`
and refreshes the optional provider SDK compatibility train:

```elixir
{:claude_agent_sdk, "~> 0.20.0", optional: true}
{:codex_sdk, "~> 0.19.0", optional: true}
{:antigravity_cli_sdk, "~> 0.3.0", optional: true}
{:amp_sdk, "~> 0.8.0", optional: true}
{:cursor_cli_sdk, "~> 0.3.0", optional: true}
```

All five SDK releases share `cli_subprocess_core 0.7`. Cursor no longer needs
the incompatibility caveat from the ASM 0.12 release. The provider SDKs remain
optional consumer dependencies: ASM itself still depends only on Core and
discovers installed SDK lanes at runtime.

There are no ASM API changes required for applications upgrading from 0.14.
