# Policy Enforcement

Feature 5 adds runtime policy enforcement in `SessionManager` with no signature changes.

Policy is opt-in per execution via `:policy` in `execute_run/4` and `run_once/4`.

## Policy Model

`AgentSessionManager.Policy.Policy` supports:

- limits:
  - `{:max_total_tokens, n}`
  - `{:max_duration_ms, n}`
  - `{:max_tool_calls, n}`
  - `{:max_cost_usd, value}`
- tool rules:
  - `{:allow, ["tool_a", ...]}`
  - `{:deny, ["tool_a", ...]}`
- `on_violation` action:
  - `:cancel`
  - `:warn`

```elixir
alias AgentSessionManager.Policy.Policy

{:ok, policy} =
  Policy.new(
    name: "production",
    limits: [{:max_total_tokens, 8_000}, {:max_duration_ms, 120_000}],
    tool_rules: [{:deny, ["bash"]}],
    on_violation: :cancel
  )
```

## Runtime Enforcement

`SessionManager` wraps the adapter event callback and evaluates policy on every event.

On each violation:

- emits `:policy_violation`
- if action is `:cancel`, invokes `ProviderAdapter.cancel(adapter, run.id)` once

## Final Result Semantics

- cancel mode:
  - if a cancel-mode violation occurred, final result is
    `{:error, %Error{code: :policy_violation}}`
  - this holds even when provider execution returned `{:ok, ...}`
- warn mode:
  - success is preserved
  - result includes violation metadata under `result.policy`

## Event and Error Taxonomy

Feature 5 adds:

- `Core.Event` type: `:policy_violation`
- `Core.Error` code: `:policy_violation`

Violation details are carried in event data:

- `policy`
- `kind`
- `action`
- `details`

## Optional Cost Checks

`{:max_cost_usd, value}` is enforced when provider rates are configured:

```elixir
config :agent_session_manager,
  policy_cost_rates: %{
    "claude" => %{input: 0.000003, output: 0.000015},
    "codex" => %{input: 0.000002, output: 0.000010},
    "amp" => %{input: 0.000002, output: 0.000010}
  }
```

When rates are unavailable for a provider, cost-limit enforcement is skipped and
runtime metadata records the warning.
