# Transport Guarantees

This guide describes what `ASM.Transport.Port` guarantees for subprocess-backed runs.

## Ownership and Lifecycle

- A transport has at most one active lease owner (`attach/2`).
- `attach/2` by a second run returns `{:error, :busy}`.
- Lease owner process death releases the lease and starts headless timeout countdown.
- Headless timeout stops orphaned subprocess transports when no lease owner is attached.
- Optional startup lease timeout can stop transports that were started but never leased.

## Delivery and Backpressure

- Delivery is demand-driven: messages flow only when lease owner requests demand.
- Queue is bounded by `queue_limit`.
- Overflow behavior is explicit and configurable:
  - `:fail_run` -> emits transport error and stops
  - `:drop_oldest` -> keeps newest entries
  - `:block` -> drops incoming when full

## Input/Output Semantics

- `send_input/3` writes to stdin (newline by default, configurable with `append_newline: false`).
- `end_input/1` sends EOF (`:exec.send(pid, :eof)`).
- `interrupt/1` sends SIGINT.
- `close/1` performs graceful close with kill escalation in transport termination paths.
- `stderr/1` returns captured stderr tail.

## Buffering and Parsing

- Stdout line framing is incremental and resilient to split chunks.
- Stdout partial-line buffering is capped by `max_stdout_buffer_bytes`.
- On stdout buffer overflow, transport emits `{:stdout_buffer_overflow, size}` and resumes at next newline.
- Stderr tail buffering is capped by `max_stderr_buffer_bytes`.
- JSON object lines are decoded and emitted as transport messages.
- Non-JSON lines are retained as diagnostics (with parse-error signaling for JSON-like malformed lines).

## Exit and Diagnostics

- Transport waits briefly after subprocess `:DOWN` to drain trailing stdout/stderr.
- Exit status normalization handles common erlexec status encodings.
- Exit notification includes diagnostics assembled from recent non-JSON stdout and stderr lines.

## Call-Surface Safety

- Public transport API wrappers use safe-call normalization:
  - typed timeout errors instead of caller exits
  - typed transport errors for not-connected/stopped paths
  - `close/1` is best-effort and non-raising
