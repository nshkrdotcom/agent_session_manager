# Cost Tracking

AgentSessionManager can estimate and persist per-run USD cost from token usage.
The cost pipeline is model-aware and supports provider defaults, model prefixes,
and cache-token pricing for Claude.

## Overview

Cost tracking has four parts:

1. `AgentSessionManager.Cost.CostCalculator` computes USD from token counts.
2. `Policy.Runtime` uses model-aware rates for `{:max_cost_usd, ...}` enforcement.
3. `SessionManager` stores `run.cost_usd` at successful finalization.
4. Query and rendering surfaces expose cost in summaries/output.

## Configuration

Set a pricing table globally:

```elixir
config :agent_session_manager,
  pricing_table: %{
    "claude" => %{
      default: %{input: 0.000003, output: 0.000015},
      models: %{
        "claude-sonnet-4-5" => %{
          input: 0.000003,
          output: 0.000015,
          cache_read: 0.0000003,
          cache_creation: 0.00000375
        }
      }
    }
  }
```

If unset, ASM uses `CostCalculator.default_pricing_table/0`.

## How Cost Is Calculated

`CostCalculator.calculate/4` computes:

```text
cost =
  input_tokens * input_rate +
  output_tokens * output_rate +
  cache_read_tokens * (cache_read_rate || input_rate) +
  cache_creation_tokens * (cache_creation_rate || input_rate)
```

Rate resolution order:

1. Exact model match.
2. Longest prefix model match (for dated model ids like `...-20250929`).
3. Provider default rate.

If no provider rates exist, calculation returns `{:error, :no_rates}`.

## Policy Enforcement

`Policy.Runtime` captures model from `:run_started` events and applies
model-specific rates for ongoing cost accumulation. If no model is captured,
provider default rates are used.

Legacy flat `policy_cost_rates` remain supported for backward compatibility.

## Querying Cost

Use `QueryAPI.get_cost_summary/2`:

```elixir
query = {AgentSessionManager.Adapters.EctoQueryAPI, MyApp.Repo}

{:ok, summary} =
  AgentSessionManager.Ports.QueryAPI.get_cost_summary(query,
    provider: "claude",
    since: DateTime.add(DateTime.utc_now(), -86_400, :second)
  )
```

Returned keys:

- `total_cost_usd`
- `run_count`
- `by_provider`
- `by_model`
- `unmapped_runs`

Runs without stored `cost_usd` are calculated post-hoc when possible.

## Rendering and Telemetry

- Compact/verbose renderers include cost labels when `cost_usd` is present.
- JSONL compact sink includes a `$` field on `token_usage_updated`.
- Run-stop telemetry includes `:cost_usd` measurement when available.

## Enterprise Pricing Tables

You can supply a custom `pricing_table` for negotiated rates, regional rates,
or internal chargeback models. A per-query override is also supported in
`get_cost_summary/2` via `:pricing_table`.

## Migration from Flat `policy_cost_rates`

Old format:

```elixir
%{"claude" => %{input: 0.000003, output: 0.000015}}
```

New structured format:

```elixir
%{
  "claude" => %{
    default: %{input: 0.000003, output: 0.000015},
    models: %{}
  }
}
```

`CostCalculator.normalize_legacy_rates/1` accepts both formats during
migration, so rollout can be incremental.
