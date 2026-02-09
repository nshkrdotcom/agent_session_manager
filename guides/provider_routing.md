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

## Weighted Routing (Phase 2)

Instead of simple preference ordering, you can use weighted scoring to rank providers:

```elixir
{:ok, router} =
  ProviderRouter.start_link(
    policy: [
      strategy: :weighted,
      weights: %{"amp" => 10, "codex" => 5, "claude" => 1},
      max_attempts: 3
    ]
  )
```

Per-run overrides via `adapter_opts`:

```elixir
{:ok, result} =
  SessionManager.execute_run(store, router, run.id,
    adapter_opts: [
      routing: [
        strategy: :weighted,
        weights: %{"amp" => 10, "codex" => 5, "claude" => 1}
      ]
    ]
  )
```

Health penalties reduce effective scores: `score = weight - failure_count * 0.5`.
Adapters with higher weights are preferred but can drop below lower-weight
adapters if they accumulate failures.

Ties are broken using the `prefer` order when configured.

## Session Stickiness (Phase 2)

Session stickiness binds a logical session to a specific adapter across multiple
runs. This is useful when providers maintain server-side conversation state.

```elixir
{:ok, router} =
  ProviderRouter.start_link(
    policy: [prefer: ["claude", "codex", "amp"]],
    sticky_ttl_ms: 300_000  # 5 minutes (default)
  )

# Both runs route to the same adapter
{:ok, result_1} =
  SessionManager.execute_run(store, router, run_1.id,
    adapter_opts: [routing: [sticky_session_id: session.id]]
  )

{:ok, result_2} =
  SessionManager.execute_run(store, router, run_2.id,
    adapter_opts: [routing: [sticky_session_id: session.id]]
  )
```

Stickiness is best-effort: if the sticky adapter becomes unavailable (cooldown
or circuit breaker), the router falls back to normal selection and updates the
binding.

## Circuit Breaker (Phase 2)

The router optionally integrates a pure-functional circuit breaker per adapter:

```elixir
{:ok, router} =
  ProviderRouter.start_link(
    policy: [prefer: ["amp", "codex", "claude"]],
    circuit_breaker_enabled: true,
    circuit_breaker_opts: [
      failure_threshold: 5,
      cooldown_ms: 30_000,
      half_open_max_probes: 1
    ]
  )
```

Circuit breaker states:

- `:closed` -- normal operation, requests allowed
- `:open` -- threshold reached, requests blocked until cooldown expires
- `:half_open` -- cooldown expired, limited probe requests test recovery

State transitions:

```
:closed --(failure threshold)--> :open
:open   --(cooldown expires)---> :half_open
:half_open --(probe succeeds)--> :closed
:half_open --(probe fails)-----> :open
```

The `CircuitBreaker` module is a pure data structure with no processes or side
effects. It is stored per adapter in router state.

## Routing Telemetry (Phase 2)

The router emits `:telemetry` events for each routing attempt:

- `[:agent_session_manager, :router, :attempt, :start]` -- before adapter execution
- `[:agent_session_manager, :router, :attempt, :stop]` -- after successful execution
- `[:agent_session_manager, :router, :attempt, :exception]` -- on adapter failure

Measurements include `system_time` and `duration` (for stop/exception).
Metadata includes `adapter_id`, `run_id`, `attempt`, and `session_id`.
