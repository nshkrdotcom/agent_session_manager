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

## Policies Stack (Phase 2)

Multiple policies can be stacked using `:policies` (list) instead of `:policy` (single):

```elixir
{:ok, org_policy} =
  Policy.new(
    name: "org",
    limits: [{:max_total_tokens, 100_000}],
    on_violation: :cancel
  )

{:ok, team_policy} =
  Policy.new(
    name: "team",
    tool_rules: [{:deny, ["bash"]}],
    on_violation: :warn
  )

{:ok, result} =
  SessionManager.execute_run(store, adapter, run.id,
    policies: [org_policy, team_policy]
  )
```

Merge semantics (deterministic, left-to-right):

- **Names**: joined with ` + ` separator (`"org + team"`)
- **Limits**: later values override earlier values of the same type
- **Tool rules**: concatenated from all policies
- **on_violation**: strictest wins (`:cancel` > `:warn`)
- **Metadata**: deep-merged (later keys override)

When both `:policies` and `:policy` are provided, `:policies` takes precedence.

## Provider-Side Enforcement (Phase 2)

For providers that support it, policies are compiled into `adapter_opts` for
best-effort provider-side enforcement. This is automatic during `execute_run/4`
-- no manual step is required.

### How It Works

`SessionManager` calls `AdapterCompiler.compile/2` before adapter execution.
The compiler translates policy rules into provider-native options:

```elixir
alias AgentSessionManager.Policy.AdapterCompiler

# Given a policy:
{:ok, policy} =
  Policy.new(
    name: "restricted",
    limits: [{:max_total_tokens, 50_000}],
    tool_rules: [{:deny, ["bash", "shell"]}, {:allow, ["read", "write"]}],
    on_violation: :cancel
  )

# Compile for a specific provider:
adapter_opts = AdapterCompiler.compile(policy, "claude")
# => [
#   denied_tools: ["bash", "shell"],
#   allowed_tools: ["read", "write"],
#   max_tokens: 50_000
# ]
```

### Mapping Rules

| Policy Rule | Compiled adapter_opt | Notes |
|---|---|---|
| `{:deny, tools}` | `denied_tools: tools` | Provider may exclude tools from responses |
| `{:allow, tools}` | `allowed_tools: tools` | Provider may restrict to only these tools |
| `{:max_total_tokens, n}` | `max_tokens: n` | Provider may cap output tokens |
| `{:max_duration_ms, n}` | (not compiled) | Duration is enforced reactively only |
| `{:max_tool_calls, n}` | (not compiled) | Tool call count is enforced reactively only |
| `{:max_cost_usd, n}` | (not compiled) | Cost is enforced reactively only |

### Merged Policy Compilation

When using `policies: [...]` stacks, the merged policy is compiled:

```elixir
{:ok, org} = Policy.new(name: "org", limits: [{:max_total_tokens, 100_000}])
{:ok, team} = Policy.new(name: "team", tool_rules: [{:deny, ["bash"]}])

# During execute_run, policies are merged first, then compiled:
# Merged: max_total_tokens=100_000, deny=["bash"]
# Compiled: [denied_tools: ["bash"], max_tokens: 100_000]
```

### Provider Support

Provider-side enforcement is best-effort. Not all providers honor all hints:

- **Claude**: Supports `denied_tools`, `allowed_tools`, and `max_tokens`
- **Codex**: Supports `denied_tools` and `max_tokens`
- **Amp**: Supports `denied_tools`

Unsupported hints are silently ignored by the adapter.

Reactive enforcement remains the safety net: even with provider-side hints,
the policy runtime still evaluates every event and enforces violations.

## Preflight Checks (Phase 2)

Before adapter execution begins, the `Preflight` module validates that a
policy is not trivially impossible:

- Empty allow list (no tools permitted)
- Zero-budget limits (`max_total_tokens: 0`, `max_duration_ms: 0`)
- Contradictory rules (allow and deny for the same tool)

If preflight fails, execution is rejected immediately with a
`{:error, %Error{code: :policy_violation}}` without calling the adapter.

```elixir
alias AgentSessionManager.Policy.Preflight

# Manual check (automatic during execute_run):
case Preflight.check(policy) do
  :ok -> # safe to proceed
  {:error, %Error{code: :policy_violation}} -> # impossible policy
end
```
