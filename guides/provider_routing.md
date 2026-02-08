# Provider Routing

Feature 4 adds a pluggable provider router that implements `ProviderAdapter`.

`SessionManager` signatures stay unchanged:

- `execute_run(store, adapter, run_id, opts \\ [])`
- `run_once(store, adapter, input, opts \\ [])`

You can pass a router process anywhere a provider adapter is accepted.

## Router As Adapter

```elixir
alias AgentSessionManager.Routing.ProviderRouter
alias AgentSessionManager.SessionManager

{:ok, router} =
  ProviderRouter.start_link(
    policy: [prefer: ["amp", "codex", "claude"], max_attempts: 3],
    cooldown_ms: 30_000
  )

:ok = ProviderRouter.register_adapter(router, "claude", claude_adapter)
:ok = ProviderRouter.register_adapter(router, "codex", codex_adapter)
:ok = ProviderRouter.register_adapter(router, "amp", amp_adapter)

{:ok, result} = SessionManager.execute_run(store, router, run.id)
```

## Capability-Driven Selection

Routing hints are forwarded through `adapter_opts`:

```elixir
{:ok, result} =
  SessionManager.execute_run(store, router, run.id,
    adapter_opts: [
      routing: [
        required_capabilities: [%{type: :tool, name: "bash"}],
        max_attempts: 2
      ]
    ]
  )
```

Capability matching supports:

- `%{type: :tool, name: "bash"}` (type + name)
- `%{type: :tool, name: nil}` (type-only fallback)

## Policy Ordering and Exclusions

Router policy controls candidate order and filtering:

- `prefer` - preferred provider IDs in priority order
- `exclude` - provider IDs to skip
- `max_attempts` - retry/failover budget

Per-run routing options can override these values.

## Health and Failover (MVP)

The router tracks simple in-process health per adapter:

- consecutive failure count
- last failure time
- cooldown window (`cooldown_ms`) for temporary skipping

On execution errors:

- retry/failover occurs only when `Error.retryable?/1` is true
- non-retryable errors stop failover immediately

## Cancel Routing

During execution, the router tracks active `run_id -> adapter` ownership.
`cancel/2` is routed to the adapter currently handling that run.

## Routing Metadata

No new routing event atoms are introduced.
Routing metadata is attached to existing event data and run results:

- `routed_provider`
- `routing_attempt`
- `routing_candidates`
- `failover_from`
- `failover_reason`
