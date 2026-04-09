# Execution Plane Alignment

ASM remains the provider-neutral session kernel above the family kits and below
product UX.

## Lower Packet And Wave 5 Session Carriage

The canonical lower-boundary contract names that ASM must now keep consistent
with the packet and Wave 5 session carriage are:

- `BoundarySessionDescriptor.v1`
- `ExecutionRoute.v1`
- `AttachGrant.v1`
- `CredentialHandleRef.v1`
- `ExecutionEvent.v1`
- `ExecutionOutcome.v1`
- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

`ASM.Execution.Config.execution_plane_contracts/0` publishes that list for the
kernel-side carrier boundary.

`ASM.Execution.Config.boundary_contract_keys/0` publishes the named boundary
metadata groups ASM consumes without reclaiming transport ownership:

- `descriptor`
- `route`
- `attach_grant`
- `replay`
- `approval`
- `callback`
- `identity`

## Ownership Rule

ASM may:

- consume durable descriptors and attach grants
- carry mapped lower intent data through `execution_surface` and
  `execution_environment`
- orchestrate provider-neutral session state

ASM must not:

- re-own transport mechanics
- expose raw `execution_plane/*` packages as the public kernel API
- reinterpret Brain or Spine policy as local transport semantics

## Provisional Minimal-Lane Note

The carrier names for:

- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

are frozen in Wave 1, but their detailed payload interiors stay provisional
until Wave 3 prove-out.
