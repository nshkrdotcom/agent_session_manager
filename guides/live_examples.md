# Live Examples

This guide shows how to run AgentSessionManager examples against live Claude, Codex, and Amp adapters.

Cursor examples are also available and use real provider execution:

- `examples/cursor_pagination.exs --provider <claude|codex|amp>`
- `examples/cursor_follow_stream.exs --provider <claude|codex|amp>`

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

# Existing live lifecycle examples
mix run examples/oneshot.exs --provider claude
mix run examples/oneshot.exs --provider codex
mix run examples/oneshot.exs --provider amp

mix run examples/live_session.exs --provider claude
mix run examples/live_session.exs --provider codex
mix run examples/live_session.exs --provider amp

mix run examples/common_surface.exs --provider claude
mix run examples/common_surface.exs --provider codex
mix run examples/common_surface.exs --provider amp

mix run examples/contract_surface_live.exs --provider claude
mix run examples/contract_surface_live.exs --provider codex
mix run examples/contract_surface_live.exs --provider amp
```

Provider-specific SDK examples:

```bash
mix run examples/claude_direct.exs
mix run examples/codex_direct.exs
mix run examples/amp_direct.exs
```

## Run the Full Suite

```bash
# Full suite: cursor examples + live providers
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
