# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/agent_session_manager/releases/tag/v0.1.0
