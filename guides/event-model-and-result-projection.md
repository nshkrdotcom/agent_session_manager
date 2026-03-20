# Event Model And Result Projection

ASM does not redefine the normalized provider runtime vocabulary. It wraps core
runtime events in a run-scoped envelope and then reduces those envelopes into a
final result.

## Event Envelope

Backends emit `CliSubprocessCore.Event` values. `ASM.Run.Server` wraps them as
`%ASM.Event{}` with:

- `run_id`
- `session_id`
- `provider`
- `kind`
- `payload`
- `core_event`
- `sequence`
- `provider_session_id`
- `timestamp`
- `metadata`

The original normalized core event remains available in `event.core_event`.

## Metadata Flow

Authoritative run metadata comes from lane/backend resolution and is merged with
incoming event metadata through ASM's internal protected-metadata merge step.

Common projected keys include:

- `provider`
- `provider_display_name`
- `requested_lane`
- `preferred_lane`
- `lane`
- `backend`
- `execution_mode`
- `lane_reason`
- `lane_fallback_reason`
- `sdk_runtime`
- `sdk_available?`
- `capabilities`

That keeps stream consumers and query consumers aligned on the same effective
runtime path.

## Final Result Projection

`ASM.Stream.final_result/1` reduces the `%ASM.Event{}` stream through
`ASM.Run.EventReducer`.

The reducer is responsible for:

- accumulating assistant text and legacy message projections
- tracking provider session id and cost totals
- tracking pending approvals
- marking terminal status on result, error, or interruption
- building `%ASM.Result{}`

`%ASM.Result.metadata` therefore comes from the event stream itself instead of a
side channel.

## Terminal Semantics

- `:result` marks the run completed successfully
- `:error` marks the run failed and becomes `%ASM.Error{}`
- `:run_completed` is the ASM-local lifecycle completion signal
- approval and cost events continue to update run state before the final result

That deterministic reducer path is the source of truth for one-shot
`ASM.query/3` result projection.
