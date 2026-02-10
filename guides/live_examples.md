# Live Examples

This guide shows how to run AgentSessionManager examples against live Claude, Codex, and Amp adapters.

Cursor examples are also available and use real provider execution:

- `examples/cursor_pagination.exs --provider <claude|codex|amp>`
- `examples/cursor_follow_stream.exs --provider <claude|codex|amp>`
- `examples/session_continuity.exs --provider <claude|codex|amp>`
- `examples/workspace_snapshot.exs --provider <claude|codex|amp>`
- `examples/provider_routing.exs --provider <claude|codex|amp>`
- `examples/policy_enforcement.exs --provider <claude|codex|amp>`
- `examples/session_runtime.exs --provider <claude|codex|amp>`
- `examples/session_subscription.exs --provider <claude|codex|amp>`
- `examples/session_limiter.exs --provider <claude|codex|amp>`
- `examples/cursor_wait_follow.exs --provider <claude|codex|amp>` -- long-poll streaming with `wait_timeout_ms`
- `examples/routing_v2.exs --provider <claude|codex|amp>` -- weighted routing and session stickiness
- `examples/policy_v2.exs --provider <claude|codex|amp>` -- policy stacks and provider-side enforcement
- `examples/session_concurrency.exs --provider <claude|codex|amp>` -- multi-slot concurrent session runtime
- `examples/stream_session.exs --provider <claude|codex|amp>` -- StreamSession one-shot lifecycle with rendering and raw modes
- `examples/noop_store_run_once.exs --provider <claude|codex|amp>` -- no-op durable mode for ephemeral one-shot runs

## Authentication

Authenticate each provider through its native CLI flow:

- Claude: `claude login` or set `ANTHROPIC_API_KEY`
- Codex: `codex login` or set `CODEX_API_KEY`
- Amp: `amp login` or set `AMP_API_KEY`

## Run Individual Examples

```bash
# Cursor examples
mix run examples/cursor_pagination.exs --provider claude
mix run examples/cursor_pagination.exs --provider codex
mix run examples/cursor_pagination.exs --provider amp

mix run examples/cursor_follow_stream.exs --provider claude
mix run examples/cursor_follow_stream.exs --provider codex
mix run examples/cursor_follow_stream.exs --provider amp

# Session continuity (Feature 2)
mix run examples/session_continuity.exs --provider claude
mix run examples/session_continuity.exs --provider codex
mix run examples/session_continuity.exs --provider amp

# Workspace snapshots and rollback (Feature 3)
mix run examples/workspace_snapshot.exs --provider claude
mix run examples/workspace_snapshot.exs --provider codex
mix run examples/workspace_snapshot.exs --provider amp

# Provider routing (Feature 4)
mix run examples/provider_routing.exs --provider claude
mix run examples/provider_routing.exs --provider codex
mix run examples/provider_routing.exs --provider amp

# Policy enforcement (Feature 5)
mix run examples/policy_enforcement.exs --provider claude
mix run examples/policy_enforcement.exs --provider codex
mix run examples/policy_enforcement.exs --provider amp

# Session runtime (Feature 6)
mix run examples/session_runtime.exs --provider claude
mix run examples/session_runtime.exs --provider codex
mix run examples/session_runtime.exs --provider amp

# Session subscriptions (Feature 6)
mix run examples/session_subscription.exs --provider claude
mix run examples/session_subscription.exs --provider codex
mix run examples/session_subscription.exs --provider amp

# Session limiter integration (Feature 6)
mix run examples/session_limiter.exs --provider claude
mix run examples/session_limiter.exs --provider codex
mix run examples/session_limiter.exs --provider amp

# Existing live lifecycle examples
mix run examples/oneshot.exs --provider claude
mix run examples/oneshot.exs --provider codex
mix run examples/oneshot.exs --provider amp

mix run examples/noop_store_run_once.exs --provider claude
mix run examples/noop_store_run_once.exs --provider codex
mix run examples/noop_store_run_once.exs --provider amp

mix run examples/live_session.exs --provider claude
mix run examples/live_session.exs --provider codex
mix run examples/live_session.exs --provider amp

mix run examples/common_surface.exs --provider claude
mix run examples/common_surface.exs --provider codex
mix run examples/common_surface.exs --provider amp

mix run examples/contract_surface_live.exs --provider claude
mix run examples/contract_surface_live.exs --provider codex
mix run examples/contract_surface_live.exs --provider amp

# Cursor long-poll follow (Phase 2)
mix run examples/cursor_wait_follow.exs --provider claude
mix run examples/cursor_wait_follow.exs --provider codex
mix run examples/cursor_wait_follow.exs --provider amp

# Routing v2: weighted scoring + stickiness (Phase 2)
mix run examples/routing_v2.exs --provider claude
mix run examples/routing_v2.exs --provider codex
mix run examples/routing_v2.exs --provider amp

# Policy v2: stacks + provider-side enforcement (Phase 2)
mix run examples/policy_v2.exs --provider claude
mix run examples/policy_v2.exs --provider codex
mix run examples/policy_v2.exs --provider amp

# Session concurrency: multi-slot runtime (Phase 2)
mix run examples/session_concurrency.exs --provider claude
mix run examples/session_concurrency.exs --provider codex
mix run examples/session_concurrency.exs --provider amp
```

Provider-specific SDK examples:

```bash
mix run examples/claude_direct.exs
mix run examples/codex_direct.exs
mix run examples/amp_direct.exs
```

## Run the Full Suite

```bash
# Full suite: cursor + continuity + workspace + live providers
bash examples/run_all.sh

# Full suite with a single live provider
bash examples/run_all.sh --provider codex
```

The suite exits non-zero if any example fails.

## Contract Surface Checks

`examples/contract_surface_live.exs` validates core runtime contract behavior:

- `result.events` contains emitted adapter events
- callback event stream is available during execution
- `:run_completed` includes `token_usage` payload

This is useful after upgrading adapters or SDK dependencies.

## Troubleshooting

### Authentication or CLI errors

Confirm the relevant CLI is installed and authenticated in your current shell session.

### Timeouts

Provider latency may vary. Re-run or reduce prompt complexity.

### Rate limits

Retry after cooldown and verify API account limits.
