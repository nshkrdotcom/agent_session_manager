# Execution Plane Alignment

ASM remains the provider-neutral session kernel above the family kits and below
product UX.

## Wave 1 Lower Packet

The canonical lower-boundary contract names that ASM must now keep consistent
with the Wave 1 packet are:

- `BoundarySessionDescriptor.v1`
- `AttachGrant.v1`
- `ExecutionEvent.v1`
- `ExecutionOutcome.v1`
- `ProcessExecutionIntent.v1`
- `JsonRpcExecutionIntent.v1`

`ASM.Execution.Config.execution_plane_contracts/0` publishes that list for the
kernel-side carrier boundary.

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
