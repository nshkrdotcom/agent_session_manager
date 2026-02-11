# Workflow Bridge

## Overview

`AgentSessionManager.WorkflowBridge` is a thin integration layer for calling ASM from external workflow/DAG engines.

It is not a workflow runtime. It wraps `SessionManager` with workflow-friendly helpers for:

- Step execution (`step_execute/3`)
- Result normalization (`step_result/2`)
- Shared session setup/teardown (`setup_workflow_session/3`, `complete_workflow_session/3`)
- Error routing decisions (`classify_error/1`)

## One-Shot Pattern

Use one-shot mode when each workflow step is independent.

```elixir
alias AgentSessionManager.WorkflowBridge

{:ok, result} =
  WorkflowBridge.step_execute(store, adapter, %{
    input: %{messages: [%{role: "user", content: "Summarize this file"}]}
  })
```

Notes:

- One-shot creates a new session per step.
- You still get normalized `StepResult` output.
- If `store` is `{module, context}`, WorkflowBridge transparently uses a multi-step fallback because `SessionManager.run_once/4` does not support module-backed tuples.

## Multi-Run Pattern

Use multi-run mode when steps need continuity across a shared session.

```elixir
alias AgentSessionManager.WorkflowBridge

{:ok, session_id} =
  WorkflowBridge.setup_workflow_session(store, adapter, %{
    agent_id: "review-workflow",
    context: %{system_prompt: "You are concise."}
  })

{:ok, _r1} =
  WorkflowBridge.step_execute(store, adapter, %{
    session_id: session_id,
    input: %{messages: [%{role: "user", content: "Remember: TOKEN-42"}]}
  })

{:ok, _r2} =
  WorkflowBridge.step_execute(store, adapter, %{
    session_id: session_id,
    input: %{messages: [%{role: "user", content: "What token?"}]},
    continuation: :auto,
    continuation_opts: [max_messages: 50]
  })

:ok = WorkflowBridge.complete_workflow_session(store, session_id)
```

Lifecycle behavior:

- `setup_workflow_session/3` creates + activates a session
- `complete_workflow_session/3` defaults to completion
- pass `status: :failed` (and optional `error:`) to fail it

## Error Classification

Use `classify_error/1` to convert ASM errors into retry/failover/abort signals.

```elixir
alias AgentSessionManager.Core.Error
alias AgentSessionManager.WorkflowBridge

classification = WorkflowBridge.classify_error(Error.new(:provider_timeout, "timed out"))
# => %{retryable: true, category: :provider, recommended_action: :retry}
```

Recommended action mapping:

| Error Code | Recommended Action |
|---|---|
| `:provider_timeout` | `:retry` |
| `:provider_rate_limited` | `:wait_and_retry` |
| `:provider_unavailable` | `:failover` |
| `:storage_connection_failed` | `:retry` |
| `:timeout` | `:retry` |
| `:max_runs_exceeded` | `:wait_and_retry` |
| `:cancelled` | `:cancel` |
| `:policy_violation` | `:cancel` |
| `:validation_error` | `:abort` |
| `:session_not_found` | `:abort` |
| `:run_not_found` | `:abort` |
| `:provider_error` | `:abort` |
| `:provider_authentication_failed` | `:abort` |
| `:provider_quota_exceeded` | `:abort` |
| any other code | `:abort` |

## Data Contract

`step_execute/3` returns `{:ok, %WorkflowBridge.StepResult{...}}`:

- `output` full provider output map
- `content` extracted output text when present
- `token_usage` token counts map
- `session_id`, `run_id` identity fields
- `events` raw event list
- `stop_reason` convenience routing signal
- `tool_calls`, `has_tool_calls` tool routing signal
- `persistence_failures` event persistence count
- `workspace`, `policy` optional execution metadata
- `retryable` reserved routing flag (currently `false` for success)

## Integration With Jido

Jido Action modules can call WorkflowBridge directly:

- per-step execution uses `step_execute/3`
- workflow setup/teardown actions use `setup_workflow_session/3` and `complete_workflow_session/3`
- failure routing uses `classify_error/1`

This keeps Jido actions thin while centralizing ASM-specific behavior in one module.

## Store Compatibility

`SessionManager.run_once/4` only accepts process-backed store references (`pid`, registered `atom`, `:via`, `:global`).

It rejects module-backed stores (`{module, context}`), which are common for persistence adapters like Ecto.

WorkflowBridge handles this automatically:

- process-backed store -> one-shot path uses `run_once/4`
- module-backed store -> one-shot path uses explicit `start_session -> activate_session -> start_run -> execute_run -> complete_session`

The caller always receives the same normalized `StepResult` contract.
