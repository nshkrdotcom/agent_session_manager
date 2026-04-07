# Approvals And Interrupts Guide

Approvals are session-scoped. Interrupts are run-scoped.

## Approval Routing

Approval events originate from the active backend run, but ownership stays at
the session aggregate.

Flow:

1. the backend emits `:approval_requested`
2. `ASM.Run.Server` wraps it as `%ASM.Event{}`
3. the run notifies `ASM.Session.Server`
4. the session indexes `approval_id` to the owning run pid
5. `ASM.approve/3` routes the final decision back to that run

If the approval is not resolved before `approval_timeout_ms`, the run emits:

- `:approval_resolved`
- `decision: :deny`
- `reason: "timeout"`

That timeout path also clears the session approval index so stale approvals do
not remain routable.

## Interrupt Control

`ASM.interrupt/2` always targets a run id.

- queued runs are removed from the session queue before they start
- active runs call the resolved backend's `interrupt/1`
- the run then emits a terminal `user_cancelled` error

The caller never needs to know whether the run is executing on the core lane,
SDK lane, or a remote node.

## Remote Execution

Remote execution does not change the public control surface:

- approvals still resolve through the local `ASM.Session.Server`
- active remote runs still interrupt through the local `ASM.Run.Server`
- the same timeout and `user_cancelled` semantics apply in local and remote mode
