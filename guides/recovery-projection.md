# Recovery Projection

`agent_session_manager` preserves lower-layer recovery facts from
`cli_subprocess_core` and projects them into ASM's own error/result surface.

This guide describes that projection seam.

## What ASM Preserves

ASM now keeps structured recovery metadata in two main places:

- stream-projected `ASM.Error` values
- streamed provider error payloads reduced through the run event reducer

That metadata flows through the `recovery` field on `ASM.Error` and through the
same recovery map carried on normalized error payload metadata.

## Why ASM Keeps The Envelope

ASM is the shared session runtime for higher callers. If it flattened the lower
recovery facts back into strings, higher runtimes would have to re-invent
provider and transport heuristics that `cli_subprocess_core` already knows.

By preserving the envelope, ASM lets upper runtimes reason about:

- whether a failure was local/deterministic
- whether it was a remote/provider claim
- whether resume/retry/repair are plausible
- any suggested delay or attempt budget emitted by the lower layer

## Ownership Boundary

ASM owns:

- preserving recovery facts across the session/runtime projection boundary
- exposing retryability on `ASM.Error`
- keeping lane/provider details intact enough for higher runtimes

ASM does not own:

- packet/job-level retry budgets
- verifier-driven completion
- repair prompt synthesis

Those remain higher-level concerns.

## Design Rule

ASM should prefer lossless projection:

- do not discard recovery metadata that came from the lower layer
- do not collapse retryability down to ad hoc message matching
- do not force upper runtimes to know provider-CLI internals

That keeps `prompt_runner_sdk` and other higher runtimes focused on workflow
policy instead of transport archaeology.
