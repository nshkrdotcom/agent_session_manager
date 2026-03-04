# Remote Node Execution Guide

`ASM` can run provider CLI subprocesses on a remote BEAM node while keeping session/run processes local.

## Enable Remote Mode

Use `execution_mode: :remote_node` and configure remote options in `driver_opts`.

```elixir
{:ok, session} =
  ASM.start_session(
    provider: :codex,
    execution_mode: :remote_node,
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

## Driver Options

- `remote_node` (required in remote mode)
- `remote_cookie` (optional)
- `remote_connect_timeout_ms` (default `5000`)
- `remote_rpc_timeout_ms` (default `15000`)
- `remote_boot_lease_timeout_ms` (default `10000`)
- `remote_bootstrap_mode`
  - `:require_prestarted` (default)
  - `:ensure_started` (attempts `Application.ensure_all_started(:agent_session_manager)` on remote node)
- `remote_cwd` (optional override for provider `cwd` on remote host)
- `remote_transport_call_timeout_ms` (default `5000`)

## Failure Semantics

Typical remote startup failures surface as terminal `%ASM.Error{}` values:

- distribution disabled locally
- connect timeout / connect failed
- cookie conflict
- remote capability/version mismatch
- remote RPC timeout/failure
- remote app bootstrap failure
- workspace creation failure
- remote CLI not found
- remote transport start failure

Runtime behavior:

- `nodedown`/partition surfaces transport error (`:noconnection` detail in message)
- remote transport crash/timeout uses normal transport error paths

## Operational Constraints

- Erlang distribution implies full trust; only connect trusted nodes
- use TLS distribution for untrusted networks
- remote node must have:
  - compatible OTP major version
  - ASM major/minor-compatible build
  - `:agent_session_manager` app available
  - provider CLI binaries + credentials
  - writable workspace path
