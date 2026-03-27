# Remote Node Execution Guide

`ASM` can start provider backends on a remote BEAM node while keeping the session and run processes local.

## Enable Remote Mode

Use `execution_mode: :remote_node` and configure remote backend options in `driver_opts`.

```elixir
{:ok, session} =
  ASM.start_session(
    provider: :codex,
    execution_mode: :remote_node,
    # Remote backend options stay under :driver_opts
    driver_opts: [
      remote_node: :"asm@sandbox-a",
      remote_cookie: :cluster_cookie,
      remote_cwd: "/workspaces/t-123"
    ]
  )
```

Per-run override:

```elixir
ASM.query(session, "run remotely",
  execution_mode: :remote_node,
  driver_opts: [remote_node: :"asm@sandbox-b"]
)
```

Per-run local override:

```elixir
ASM.query(session, "run locally", execution_mode: :local)
```

`ASM.ProviderBackend.Core` is the source of truth for remote execution. The optional SDK lane is local-only.

`ASM.Schema.RemoteNode` now owns the resolved remote execution payload after ASM
applies precedence rules. That keeps remote-node validation in one place and
preserves forward-compatible fields on the resolved map rather than scattering
manual checks across the backend path.

## Lane Behavior In Remote Mode

Lane resolution remains discovery-driven even when the run executes remotely.

- `lane: :core` executes remotely on `ASM.ProviderBackend.Core`
- `lane: :auto` still prefers `:sdk` when a local runtime kit is installed, but the landed Phase 3 remote boundary falls back to `lane: :core`
- `lane: :sdk` with `execution_mode: :remote_node` is rejected as a configuration error

This means remote results and streamed events can show:

- `requested_lane: :auto`
- `preferred_lane: :sdk`
- `lane: :core`
- `lane_fallback_reason: :sdk_remote_unsupported`

Example `%ASM.Result.metadata` shape for that case:

```elixir
%{
  requested_lane: :auto,
  preferred_lane: :sdk,
  lane: :core,
  backend: ASM.ProviderBackend.Core,
  execution_mode: :remote_node,
  lane_fallback_reason: :sdk_remote_unsupported
}
```

Use `ASM.ProviderRegistry.resolve/2` when you need to inspect the effective backend choice before starting a run.

## Remote Options

- `remote_node` (required in remote mode)
- `remote_cookie` (optional)
- `remote_connect_timeout_ms` (default `5000`)
- `remote_rpc_timeout_ms` (default `15000`)
- `remote_boot_lease_timeout_ms` (accepted for config compatibility and carried in the resolved execution config, but not consumed by the current remote backend start path)
- `remote_bootstrap_mode`
  - `:require_prestarted` (default)
  - `:ensure_started` (attempts `Application.ensure_all_started(:agent_session_manager)` on remote node)
- `remote_cwd` (optional override for provider `cwd` on remote host)
- `remote_transport_call_timeout_ms` (default `5000`; overrides `transport_call_timeout_ms` for remote backend control calls)

## Failure Semantics

Typical remote startup failures surface as terminal `%ASM.Error{}` values:

- distribution disabled locally
- connect timeout / connect failed
- cookie conflict
- remote capability/version mismatch
- remote RPC timeout/failure
- remote app bootstrap failure
- remote backend start failure

Runtime behavior:

- `nodedown`/partition surfaces a terminal runtime error from the backend monitor path
- remote backend crash/timeout uses the same terminal error path as local backend crashes

## Approval Routing And Interrupts

Remote execution does not change the control surface that callers use.

Approval flow:

- the remote backend emits an approval event
- the local `ASM.Run.Server` wraps it as `%ASM.Event{}`
- the local `ASM.Session.Server` indexes `approval_id` to the owning run
- `ASM.approve/3` routes the decision back to that run

If `approval_timeout_ms` expires first, ASM emits `:approval_resolved` with `decision: :deny` and `reason: "timeout"`.

Interrupt flow:

- `ASM.interrupt/2` targets a run id, not a backend implementation
- queued runs are removed locally before they start
- active remote runs forward the interrupt through the core backend control path
- the run terminates with the same `user_cancelled` semantics used in local mode

## Event And Result Observability

Remote runs use the same `%ASM.Event{}` and `%ASM.Result{}` projection model as local runs. The effective backend choice is visible in stream and result metadata, including:

- `requested_lane`
- `preferred_lane`
- `lane`
- `backend`
- `execution_mode`
- `lane_fallback_reason`

## Operational Constraints

- Erlang distribution implies full trust; only connect trusted nodes
- use TLS distribution for untrusted networks
- remote node must have:
  - compatible OTP major version
  - ASM major/minor-compatible build
  - `:agent_session_manager` app available
  - provider CLI binaries + credentials
  - writable workspace path
