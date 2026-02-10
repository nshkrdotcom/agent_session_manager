# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-02-09

### Added

- **Generic rendering system** with pluggable Renderer x Sink architecture (`AgentSessionManager.Rendering`)
  - `Rendering.stream/2` orchestrator consumes any `Enumerable` of event maps, renders each event, and writes to all sinks simultaneously
  - Full lifecycle: init → render loop → finish → flush → close
- **`Renderer` behaviour** with three built-in implementations
  - `CompactRenderer` — single-line token format (`r+`, `r-`, `t+Name`, `t-Name`, `>>`, `tk:N/M`, `msg`, `!`, `?`) with optional ANSI color support via `:color` option
  - `VerboseRenderer` — line-by-line bracketed format (`[run_started]`, `[tool_call_started]`, etc.) with inline text streaming and labeled fields
  - `PassthroughRenderer` — no-op renderer returning empty iodata for every event, for use with programmatic sinks
- **`Sink` behaviour** with four built-in implementations
  - `TTYSink` — writes rendered iodata to a terminal device (`:stdio` default), preserving ANSI codes
  - `FileSink` — writes rendered output to a plain-text file with ANSI codes stripped; supports both `:path` (owns the file) and `:io` (pre-opened device, caller manages lifecycle) options
  - `JSONLSink` — writes events as JSON Lines with `:full` mode (all fields, ISO 8601 timestamps) and `:compact` mode (abbreviated type codes, millisecond epoch timestamps)
  - `CallbackSink` — forwards raw events and rendered iodata to a 2-arity callback function for programmatic processing
- **ANSI color support** in `CompactRenderer` with configurable `:color` option (default `true`)
- **`StreamSession`** one-shot streaming session lifecycle module
  - `StreamSession.start/1` replaces ~35 lines of hand-rolled boilerplate (store + adapter + task + Stream.resource + cleanup) with a single function call
  - Returns `{:ok, stream, close_fun, meta}` — a lazy event stream, idempotent close function, and metadata map
  - Automatic `InMemorySessionStore` creation when no store is provided
  - Adapter startup from `{Module, opts}` tuples; passes through existing pids/names without ownership
  - Ownership tracking: only terminates resources that StreamSession created
  - Configurable idle timeout (default 120s) and shutdown grace period (default 5s)
  - Error events emitted for adapter failures, task crashes, exceptions, and timeouts (never crashes the consumer)
  - Atomic idempotent close via `:atomics.compare_exchange`
- **`StreamSession.Supervisor`** convenience supervisor for production use
  - Starts `Task.Supervisor` and `DynamicSupervisor` for managed task and adapter lifecycle
  - Optional — StreamSession works without it using `Task.start_link` directly
- **`StreamSession.Lifecycle`** resource acquisition and release (store, adapter, task)
- **`StreamSession.EventStream`** lazy `Stream.resource` with receive-based state machine
- Four new rendering examples: `rendering_compact.exs`, `rendering_verbose.exs`, `rendering_multi_sink.exs`, `rendering_callback.exs`
- New example: `stream_session.exs` demonstrating StreamSession in rendering and raw modes
- New guides: `guides/rendering.md`, `guides/stream_session.md`
- Rendering test helpers in `test/support/rendering_helpers.ex`
- Full test coverage for all renderers, sinks, and StreamSession

### Changed

- Rendering examples refactored to use `StreamSession.start/1`, eliminating duplicated `build_event_stream` boilerplate from each
- `examples/run_all.sh` updated with StreamSession and rendering example entries

### Documentation

- Add `guides/rendering.md` and `guides/stream_session.md` to HexDocs extras and "Core Concepts" group
- Add Rendering and Stream Session module groups to HexDocs
- Update `examples/README.md` with rendering and StreamSession example documentation
- Add rendering and StreamSession sections to `README.md`
- Bump installation snippets in `README.md` and `guides/getting_started.md` to `~> 0.7.0`

## [0.6.0] - 2026-02-08

### Added

- **Normalized `max_turns` option** for controlling agentic loop turn limits across all adapters
  - Claude: `nil` (default) = unlimited turns, integer = pass `--max-turns N` to CLI
  - Codex: `nil` (default) = SDK default of 10, integer = override via `RunConfig`
  - Amp: stored but ignored (CLI-enforced, no SDK knob)
- **Normalized `system_prompt` option** for configuring system prompts across adapters
  - Claude: maps to `system_prompt` on `ClaudeAgentSDK.Options`
  - Codex: maps to `base_instructions` on `Codex.Thread.Options`
  - Amp: stored in state (no direct SDK equivalent)
- **`sdk_opts` passthrough** for arbitrary provider-specific SDK options
  - All adapters accept `:sdk_opts` keyword list, merged into the underlying SDK options struct
  - Normalized options (`:permission_mode`, `:max_turns`, etc.) always take precedence over `sdk_opts`
  - Unknown keys are silently ignored (only struct-valid fields are applied)
- **Normalized permission modes** via `AgentSessionManager.PermissionMode` with provider-specific mapping
  - Five modes: `:default`, `:accept_edits`, `:plan`, `:full_auto`, `:dangerously_skip_permissions`
  - `PermissionMode.all/0`, `valid?/1`, and `normalize/1` for validation and string/atom coercion
  - ClaudeAdapter maps `:full_auto` and `:dangerously_skip_permissions` to `permission_mode: :bypass_permissions` on `ClaudeAgentSDK.Options`
  - CodexAdapter maps `:full_auto` to `full_auto: true` and `:dangerously_skip_permissions` to `dangerously_bypass_approvals_and_sandbox: true` on `Codex.Thread.Options`
  - AmpAdapter maps `:full_auto` and `:dangerously_skip_permissions` to `dangerously_allow_all: true` on `AmpSdk.Types.Options`
  - `:accept_edits` and `:plan` are Claude-specific; no-op on Codex and Amp adapters
  - All three adapters accept `:permission_mode` option on `start_link/1`
  - ClaudeAdapter `execute_with_agent_sdk` now forwards built SDK options through `query/3` (was `%{}`)
- **Long-poll cursor reads** via optional `wait_timeout_ms` parameter on `SessionStore.get_events/3`
  - `InMemorySessionStore` implements deferred-reply long-poll using `GenServer.reply/2` without blocking the server loop
  - `SessionManager.stream_session_events/3` forwards `wait_timeout_ms` to the store, eliminating busy polling when supported
  - Stores that do not support `wait_timeout_ms` ignore it and fall back to immediate return (backward compatible)
  - `cursor_wait_follow.exs` live example demonstrating long-poll follow
- **Adapter event metadata persistence** in `SessionManager.handle_adapter_event/4`
  - Adapter-provided `DateTime` timestamps stored in `Event.timestamp` instead of `DateTime.utc_now()`
  - Adapter-provided `metadata` map merged into `Event.metadata`
  - `Event.metadata[:provider]` always set to the adapter's provider name string
- **Native continuation modes** for session continuity
  - `:continuation` option expanded to accept `:auto`, `:replay`, `:native`, `true`, and `false`
  - `:native` mode uses provider-native session continuation (errors if unsupported)
  - `:replay` mode always replays transcript from events regardless of provider support
  - `:auto` mode (and `true` alias) uses native when available, falls back to replay
- **Token-aware transcript truncation** via `continuation_opts`
  - `max_chars` -- hard character budget for transcript content
  - `max_tokens_approx` -- approximate token budget using 4-chars-per-token heuristic
  - Truncation keeps the most recent messages within the lower effective limit
- **Per-provider continuation handles** stored under `session.metadata[:provider_sessions]` keyed map for multi-provider sessions
- **Workspace artifact storage** via `ArtifactStore` port and `FileArtifactStore` adapter
  - Large patches stored as artifacts with `patch_ref` in run metadata instead of embedding raw patches
  - `ArtifactStore.put/3`, `get/2`, `delete/2` API
  - Without an artifact store configured, patches are embedded directly (backward compatible)
- **Git snapshot untracked file support** using alternate `GIT_INDEX_FILE` to stage all content without mutating `HEAD`
  - Snapshot metadata includes `head_ref`, `dirty`, and `includes_untracked` fields
- **Hash backend configurable ignore rules** via `ignore: [paths: [...], globs: [...]]`
- **Weighted provider routing** via `strategy: :weighted` with custom weight maps and health-based score penalties
  - Score formula: `weight - failure_count * 0.5`; ties broken by `prefer` order
  - Per-run weight overrides via `adapter_opts: [routing: [weights: ...]]`
- **Session stickiness** via `sticky_session_id` in routing options with configurable `sticky_ttl_ms`
  - Best-effort: falls back to normal selection when sticky adapter is unavailable
- **Circuit breaker** for per-adapter fault isolation (`:closed` / `:open` / `:half_open` states)
  - Pure-functional data structure stored in router state, no extra processes
  - Configurable `failure_threshold`, `cooldown_ms`, and `half_open_max_probes`
- **Routing telemetry** events: `[:agent_session_manager, :router, :attempt, :start | :stop | :exception]`
- **Policy stacks** via `policies: [...]` list option with deterministic left-to-right merge semantics
  - Names joined with ` + `, limits overridden by later values, tool rules concatenated, strictest `on_violation` wins
- **Provider-side enforcement** via `AdapterCompiler` compiling policy rules to `adapter_opts`
  - Deny rules to `denied_tools`, allow rules to `allowed_tools`, token limits to `max_tokens`
  - Reactive enforcement remains the safety net alongside provider-side hints
- **Policy preflight checks** reject impossible policies (empty allow lists, zero budgets, contradictory rules) before adapter execution
- **Multi-slot concurrent session runtime** (`max_concurrent_runs > 1`) in `SessionServer`
  - Submitted runs queue in FIFO order, dequeued as slots free up
  - Automatic slot release on completion, failure, cancellation, and task crash
- **Durable subscriptions** with gap-safe backfill + live delivery in `SessionServer`
  - `subscribe/2` with `from_sequence:` replays stored events then follows live appends
  - Cursor-based resumption after disconnect: re-subscribe with `last_seen_seq + 1`
- **Transcript caching** in `SessionServer` using `TranscriptBuilder.update_from_store/3` for incremental updates
  - Cache reduces store reads from O(total_events) to O(new_events) per run
  - Invalidated on error; correctness does not depend on cache
- **Runtime telemetry** events under `[:agent_session_manager, :runtime, ...]` namespace
  - `run:enqueued`, `run:started`, `run:completed`, `run:crashed`, `drain:complete`
- **ConcurrencyLimiter and ControlOperations integration** with `SessionServer` via `:limiter` and `:control_ops` options
  - Crash-safe acquire/release and cancellation routing through the runtime layer
- New examples: `cursor_wait_follow.exs`, `routing_v2.exs`, `policy_v2.exs`, `session_concurrency.exs`
- New guide: `guides/advanced_patterns.md` covering cross-feature integration patterns

### Fixed

- **ClaudeAdapter `max_turns: 1` hardcoding** -- Claude was limited to a single turn, preventing tool results from being fed back to the model. Now defaults to `nil` (unlimited).
- **ClaudeAdapter streaming halted on tool use** -- `handle_streaming_event(%{type: :message_stop})` unconditionally halted the stream, cutting off multi-turn tool use. Now continues when `stop_reason` is `"tool_use"`, allowing the CLI to execute tools and deliver subsequent turns.
- **ClaudeAdapter missing `cwd` passthrough** -- The adapter never passed `cwd` to `ClaudeAgentSDK.Options`, so the Claude CLI ran in the Elixir process's working directory instead of the configured project directory. Now accepts `:cwd` option and passes it through.
- **ClaudeAdapter `setting_sources: ["user"]` hardcoding** -- removed; use `sdk_opts: [setting_sources: [...]]` to configure.

### Changed

- **SessionStore port** `get_events/3` now accepts optional `wait_timeout_ms` parameter (non-breaking; stores may ignore it)
- `InMemorySessionStore` extended with waiter tracking for long-poll support
- `session_continuity.exs` and `workspace_snapshot.exs` examples updated with Phase 2 features
- `examples/run_all.sh` updated with full Phase 2 provider matrix

### Documentation

- Add routing and runtime telemetry event tables with measurements and metadata to `guides/telemetry_and_observability.md`
- Expand `AdapterCompiler` section in `guides/policy_enforcement.md` with mapping rules table, merged policy compilation, and provider support matrix
- Add multi-slot worked example and transcript caching section to `guides/session_server_runtime.md`
- Add new Phase 2 examples to `guides/live_examples.md`
- Add `guides/advanced_patterns.md` covering routing + policies, SessionServer + subscriptions + workspace, stickiness + continuity, and policy + workspace + artifacts
- Update `guides/cursor_streaming_and_migration.md` with long-poll reference implementation
- Update `guides/session_continuity.md` with continuation modes, token-aware truncation, and per-provider handles
- Update `guides/workspace_snapshots.md` with artifact store, untracked file support, and ignore rules
- Update `guides/provider_routing.md` with weighted routing, stickiness, circuit breaker, and routing telemetry
- Update `guides/policy_enforcement.md` with policy stacks, provider-side enforcement, and preflight checks
- Update `guides/session_server_runtime.md` with multi-slot concurrency and operational APIs
- Update `guides/session_server_subscriptions.md` with durable subscriptions and multi-slot interleaving
- Bump installation snippets in `README.md` and `guides/getting_started.md` to `~> 0.6.0`

## [0.5.1] - 2026-02-07

### Changed

- **Canonical tool event payloads** across all three adapters (Claude, Codex, Amp)
  - All `tool_call_started`, `tool_call_completed`, and `tool_call_failed` events now emit canonical keys: `tool_call_id`, `tool_name`, `tool_input`, and `tool_output`
  - Provider-native aliases (`call_id`, `tool_use_id`, `arguments`, `input`, `output`, `content`) are still emitted alongside canonical keys for backward compatibility
  - `normalize_tool_input/1` helper added to each adapter to guarantee `tool_input` is always a map
  - `find_tool_call/2` helper added to AmpAdapter to enrich `tool_call_completed` and `tool_call_failed` events with `tool_name` and `tool_input` from the originating tool call

### Documentation

- Update `guides/provider_adapters.md` with canonical tool event payload reference
- Update `guides/session_continuity.md` with `tool_call_id` normalization note
- Bump installation snippets in `README.md` and `guides/getting_started.md` to `~> 0.5.1`

## [0.5.0] - 2026-02-07

### Added

- **AmpAdapter** for Sourcegraph Amp provider integration, bringing the adapter count to three (Claude, Codex, Amp)
  - Streaming execution, tool call handling, and cancel support via transport close
  - Amp SDK message types mapped to canonical normalized events
  - `amp_direct.exs` example demonstrating threads, permissions, MCP, and modes
- **Cursor-backed event streaming** with durable per-session sequence numbers
  - `append_event_with_sequence/2` and `get_latest_sequence/2` callbacks on the `SessionStore` port
  - `:after` and `:before` cursor filters on `get_events/3` for sequence-based pagination
  - `SessionManager.stream_session_events/3` for resumable follow/poll consumption across reconnects
  - `cursor_pagination.exs` and `cursor_follow_stream.exs` live provider examples
- **Session continuity** with provider-agnostic transcript reconstruction
  - `Transcript` struct and `TranscriptBuilder` with `from_events/2`, `from_store/3`, and `update_from_store/2`
  - Sequence-based ordering with timestamp and deterministic tie-breaker fallbacks
  - Streaming chunk collapse into single assistant messages
  - Tool call ID normalization across `tool_call_id`, `tool_use_id`, and `call_id` variants
  - `continuation: true` and `continuation_opts` support in `execute_run/4` and `run_once/4`
  - Transcript-aware prompt building in all three adapters
  - `session_continuity.exs` live provider example
- **Workspace snapshots** with pre/post snapshot, diff, and optional rollback instrumentation
  - `Workspace` service with `GitBackend` (snapshots, diffs, patch capture, rollback) and `HashBackend` (snapshots and diffs only)
  - `Snapshot` and `Diff` structs with `to_map` and summary helpers
  - `:workspace_snapshot_taken` and `:workspace_diff_computed` event types
  - Run metadata enrichment with compact diff summaries
  - `workspace: [...]` option support in `execute_run/4` and `run_once/4`
  - `workspace_snapshot.exs` live provider example
- **Provider routing** via `ProviderRouter` implementing the `ProviderAdapter` behaviour
  - Capability-driven adapter selection with type+name and type-only matching
  - `RoutingPolicy` with prefer/exclude ordering and attempt limiting
  - Simple in-process health tracking with consecutive-failure counts and cooldown-based temporary skipping
  - Retryable failover up to configured attempt limit (only for `Error.retryable?/1` errors)
  - Cancel routing to the adapter currently handling the active run
  - Routing metadata (`routed_provider`, `routing_attempt`, `failover_from`, `failover_reason`) attached to results and events
  - `provider_routing.exs` live provider example
- **Policy enforcement** opt-in per execution via `:policy` in `execute_run/4` and `run_once/4`
  - `Policy` struct with limits (`max_total_tokens`, `max_duration_ms`, `max_tool_calls`, `max_cost_usd`), tool rules (allow/deny), and `on_violation` action (`:cancel` or `:warn`)
  - `Evaluator` for pure policy checks against runtime state snapshots
  - `Runtime` GenServer for mutable per-run counters and single-cancel semantics
  - `:policy_violation` event type and error code
  - Cancel mode overrides provider success; warn mode preserves success with violation metadata
  - Optional cost-limit enforcement using configured provider token rates
  - `policy_enforcement.exs` live provider example
- **SessionServer** opt-in per-session runtime GenServer with FIFO queueing and subscriptions
  - `submit_run/3`, `await_run/3`, `execute_run/3`, `cancel_run/2`, `subscribe/2`, `unsubscribe/2`, `status/1` API
  - Strict sequential execution (MVP constraint: `max_concurrent_runs` must be `1`)
  - `RunQueue` pure FIFO data structure with enqueue/dequeue/remove and max size enforcement
  - Queued run cancellation marks `:cancelled` in store with `:run_cancelled` event without reaching adapter
  - Store-backed subscriptions delivering `{:session_event, session_id, event}` with `from_sequence` cursor replay, `run_id` filtering, and `type` filtering
  - Optional `ConcurrencyLimiter` integration via `:limiter` option for run slot acquire/release
  - Task crash handling via `Process.monitor` with automatic limiter release and awaiter notification
- **SessionSupervisor** with `DynamicSupervisor` and `Registry` child tree for per-session process lifecycle
- **SessionRegistry** with `via_tuple/2` and `lookup/2` helpers for named registration
- `AmpMockSDK` with scenario-based event stream generation for adapter testing without network
- `BlockingTestAdapter` for deterministic sequential execution testing
- `RouterTestAdapter` with configurable outcomes, sleep/cancel support, and scripted event emission
- `session_runtime.exs`, `session_subscription.exs`, and `session_limiter.exs` live provider examples
- Input messages persisted as `:message_sent` events before adapter execution

### Changed

- **SessionStore port** now requires `append_event_with_sequence/2` and `get_latest_sequence/2` callbacks (breaking for custom store implementations)
- **SessionManager** routes all event persistence through sequenced appends with monotonic per-session sequence numbers
- Sequence numbers included in telemetry event data for adapter callback events
- All three adapters (Claude, Codex, Amp) prepare transcript-aware prompts when session transcript context is present
- `InMemorySessionStore` tracks per-session sequence counters with full sequenced event storage and idempotent duplicate detection
- `amp_sdk` added as a dependency
- Existing examples (`oneshot`, `live_session`, `common_surface`, `contract_surface_live`) updated to support the `amp` provider
- `run_all.sh` refactored with argument parsing, `--provider` filtering, and run plan display

### Documentation

- Add `guides/cursor_streaming_and_migration.md` with migration checklist for custom stores
- Add `guides/session_continuity.md` and `guides/workspace_snapshots.md`
- Add `guides/provider_routing.md` and `guides/policy_enforcement.md`
- Add `guides/session_server_runtime.md` and `guides/session_server_subscriptions.md`
- Update `guides/architecture.md` module map with all new subsystems (routing, policy, workspace, runtime)
- Update `guides/concurrency.md` with runtime limiter integration
- Update `guides/events_and_streaming.md` with cursor APIs and workspace/policy event types
- Update `guides/sessions_and_runs.md` with feature options and sequence assignment
- Update `guides/live_examples.md` with all new example scripts
- Update `guides/provider_adapters.md` with AmpAdapter documentation
- Update `README.md` with SessionServer usage, cursor streaming, continuity, workspace, routing, and policy sections
- Update `examples/README.md` for three-provider support and all new examples
- Add Routing, Policy, Runtime, and Workspace modules to HexDocs group listings and extras menu
- Bump installation snippets in `README.md` and `guides/getting_started.md` to `~> 0.5.0`

## [0.4.1] - 2026-02-06

### Changed

- Harden adapter execution lifecycle in Claude and Codex adapters by replacing linked worker processes with supervised `Task.Supervisor.async_nolink/2` tasks
- Add deterministic task result and `:DOWN` handling so adapter calls always resolve with tuple results, including worker-failure paths
- Fix concurrent execution reply routing to avoid reply loss when run IDs collide
- Standardize adapter cancellation success return shape to `{:ok, run_id}` and align control operations with this contract
- Normalize `ControlOperations.interrupt/2` to use provider `cancel/2` semantics, avoiding unsafe provider-specific interrupt calls
- Remove `Process.whereis` check-then-act dispatch race in `ProviderAdapter` and use call-first fallback behavior on `:noproc`
- Replace dynamic atom creation in core deserialization paths with safe existing-atom conversion via shared serialization utilities
- Expand `Core.Error` taxonomy for stream/state mismatch cases (`:stream_closed`, `:context_mismatch`, `:invalid_cursor`, `:session_mismatch`, `:run_mismatch`)

### Added

- A shared core serialization utility for safe key conversion and map helpers
- Serialization safety tests and adapter worker-failure isolation tests

### Documentation

- Update provider and architecture guides to document supervised nolink adapter task execution model
- Document interrupt-to-cancel behavior in the concurrency guide
- Bump installation snippets in `README.md` and `guides/getting_started.md` to `~> 0.4.1`

## [0.4.0] - 2026-02-06

### Changed

- Ensure adapter `execute/4` results include emitted execution events in `result.events` for both Claude and Codex adapters
- Ensure Claude `:run_completed` events include `token_usage` on both streaming and `ClaudeAgentSDK` query execution paths
- Normalize adapter callback event aliases (for example `"run_start"`, `"delta"`, `"run_end"`) to canonical `Event.type` values before persistence in `SessionManager`
- Update SessionManager telemetry emission to use normalized event types on ingest
- Bump codex_sdk dependency from ~> 0.7.1 to ~> 0.7.2

### Added

- New live example: `examples/contract_surface_live.exs` to verify runtime contract guarantees across Claude and Codex
- New live example test: `test/examples/contract_surface_live_test.exs`
- New guide: `guides/live_examples.md`
- Add live contract-surface example runs to `examples/run_all.sh`
- Add HexDocs extras/menu entry for `guides/live_examples.md`

### Documentation

- Update `README.md` and `guides/getting_started.md` dependency snippets to `~> 0.4.0`
- Remove stale mock-mode example commands from top-level docs and guide snippets
- Expand provider/events docs to reflect current `execute/4` events contract and ingest normalization behavior

## [0.3.0] - 2026-02-06

### Changed

- Switch ClaudeAdapter from `ClaudeAgentSDK.Query.run/3` to `ClaudeAgentSDK.Streaming` for real token-level streaming deltas
- Simplify event mapping: replace `content_block_start/delta/stop` with `text_delta` and `tool_use_start` events
- Change default model from `claude-sonnet-4-20250514` to `claude-haiku-4-5-20251001`
- Add `tools` option passthrough to ClaudeAdapter `start_link/1` and SDK options
- Set `max_turns: 1` in SDK options for single-turn execution
- Update oneshot example to stream content deltas to stdout instead of progress dots to stderr
- Bump claude_agent_sdk dependency from ~> 0.10.0 to ~> 0.11.0
- Bump codex_sdk dependency from ~> 0.6.0 to ~> 0.7.1

## [0.2.1] - 2026-02-05

### Changed

- Bump claude_agent_sdk dependency from ~> 0.9.2 to ~> 0.10.0

## [0.2.0] - 2026-02-05

### Added

- `SessionManager.run_once/4` convenience function that collapses the full session lifecycle (create, activate, start run, execute, complete/fail) into a single call
- `execute_run/4` now accepts an `:event_callback` option for real-time event streaming alongside internal persistence
- `examples/oneshot.exs` one-shot execution example using `run_once/4`

## [0.1.1] - 2026-01-27

### Added

- `AgentSessionManager.Config` module for centralized configuration with process-local overrides
- Process-local configuration layering (process dictionary -> application env -> built-in default)
- Process isolation test for `Telemetry.set_enabled/1`
- `common_surface.exs` example demonstrating provider-agnostic SessionManager lifecycle
- `claude_direct.exs` example demonstrating Claude-specific SDK features (Orchestrator, Streaming, Hooks, Agent profiles)
- `codex_direct.exs` example demonstrating Codex-specific SDK features (Threads, Options, Sessions)
- Tests for all new example scripts (`common_surface_test.exs`, `claude_direct_test.exs`, `codex_direct_test.exs`)
- Configuration guide (`guides/configuration.md`) documenting the layered config system

### Changed

- `AuditLogger.set_enabled/1` now sets a process-local override instead of mutating global application env
- `Telemetry.set_enabled/1` now sets a process-local override instead of mutating global application env
- `AuditLogger.enabled?/0` and `Telemetry.enabled?/0` now resolve through `AgentSessionManager.Config.get/1`
- Telemetry tests run with `async: true` (previously `async: false` due to global state mutation)
- Telemetry `refute_event` helper now filters by `session_id` to avoid false failures from concurrent tests
- Standardized test process cleanup using `cleanup_on_exit/1` from Supertester, replacing manual `on_exit` blocks
- Updated `examples/run_all.sh` to include the new example scripts
- Updated `examples/README.md` with documentation for all new examples

## [0.1.0] - 2026-01-27

### Added

- Initial project setup
- Basic project structure with mix.exs configuration
- Project logo and assets

[Unreleased]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/agent_session_manager/releases/tag/v0.1.0
