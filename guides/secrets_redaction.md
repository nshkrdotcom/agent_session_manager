# Secrets Redaction

`AgentSessionManager.Persistence.EventRedactor` redacts secrets in event payloads
before persistence.

## Overview

Adapter events can contain API keys, passwords, tokens, connection strings, and
private key material. Persisting those values creates long-term leakage risk in
stores, transcripts, and downstream consumers that read persisted events.
This includes nested provider diagnostics like `provider_error.stderr`.

When enabled, redaction scans event payloads and replaces matches with
`[REDACTED]` (or a configured replacement).

## Quick Start

Enable redaction in your app config:

```elixir
config :agent_session_manager,
  redaction_enabled: true
```

With this enabled, persisted events from `EventPipeline` are redacted before
they are written to the `SessionStore`.

## How It Works

Redaction is inserted in `EventBuilder.process/2` between:

1. `build_event/2`
2. `enrich/2`
3. `validate/1`

Behavior:

- Scans `event.data` by default
- Optionally scans `event.metadata` (`redaction_scan_metadata`)
- Supports recursive traversal of nested maps/lists (`redaction_deep_scan`)
- Deep-scans nested error payloads (`provider_error`, `details`) on
  `:error_occurred`, `:run_failed`, and `:session_failed` events
- Skips low-risk event types via an internal skip list
- Emits telemetry when redaction occurs:
  `[:agent_session_manager, :persistence, :event_redacted]`

## Configuration Reference

| Key | Type | Default | Description |
|---|---|---|---|
| `:redaction_enabled` | `boolean()` | `false` | Master on/off switch (opt-in). |
| `:redaction_patterns` | `:default \| list \| {:replace, list}` | `:default` | Pattern source. List appends to defaults; `{:replace, list}` replaces defaults. |
| `:redaction_replacement` | `String.t() \| :categorized` | `"[REDACTED]"` | Replacement mode. |
| `:redaction_deep_scan` | `boolean()` | `true` | Scan all nested string values (`true`) or only type-targeted fields (`false`). |
| `:redaction_scan_metadata` | `boolean()` | `false` | Scan `event.metadata` in addition to `event.data`. |

## Default Pattern Library

Built-in categories include:

- `:aws_access_key`, `:aws_secret_key`, `:gcp_api_key`
- `:anthropic_key`, `:openai_key`, `:openai_legacy_key`
- `:github_pat`, `:github_oauth`, `:github_app`, `:github_refresh`, `:github_fine_pat`, `:gitlab_token`
- `:jwt_token`, `:bearer_token`
- `:password`, `:api_key_generic`, `:secret_key`, `:access_token`, `:auth_token`
- `:connection_string`
- `:private_key`
- `:env_secret`

Examples matched by defaults:

- `AKIAIOSFODNN7EXAMPLE`
- `sk-ant-api03-...`
- `ghp_...`
- `password=hunter2`
- `postgres://user:pass@host/db`
- `-----BEGIN RSA PRIVATE KEY-----`

## Custom Patterns

Append custom patterns to defaults:

```elixir
config :agent_session_manager,
  redaction_enabled: true,
  redaction_patterns: [
    {:internal_token, ~r/MYCO_TOKEN_[A-Z0-9]{32}/}
  ]
```

Replace defaults entirely:

```elixir
config :agent_session_manager,
  redaction_enabled: true,
  redaction_patterns: {:replace, [{:only_this, ~r/ONLY_SECRET_\w+/}]}
```

Per-context override (pipeline call site):

```elixir
context = %{
  session_id: "ses_123",
  run_id: "run_456",
  provider: "claude",
  redaction: %{enabled: true, replacement: :categorized}
}
```

## Replacement Modes

Flat replacement (default):

- `password=hunter2` -> `[REDACTED]`

Categorized replacement:

- `AKIA...` -> `[REDACTED:aws_access_key]`

Use categorized mode for debugging and pattern-tuning without exposing secrets.

## Bypass Vector (Important)

`SessionManager` user `event_callback` and adapter telemetry emissions receive
raw event maps, not the redacted persisted `Event` struct. That means callback
consumers can still see unredacted values unless they opt in.

Use `redact_map/2` in callbacks:

```elixir
alias AgentSessionManager.Persistence.EventRedactor

event_callback = fn event_data ->
  event_data
  |> EventRedactor.redact_map(%{enabled: true})
  |> MyApp.handle_event()
end
```

## Performance Notes

- Redaction is opt-in and zero-cost when disabled.
- Known low-risk event types are skipped.
- `redaction_deep_scan: false` limits scanning scope for better throughput.
- Very large outputs can still be scanned; tune patterns and scan scope for your workload.

## FAQ

### How do I disable redaction for one test?

```elixir
AgentSessionManager.Config.put(:redaction_enabled, false)
on_exit(fn -> AgentSessionManager.Config.delete(:redaction_enabled) end)
```

### How do I add company-specific secrets?

Add custom regex patterns with categories via `:redaction_patterns`, or pass a
per-context `redaction` override with custom patterns for selected runs.
