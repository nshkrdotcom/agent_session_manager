# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] - 2026-02-10

### Added

- **Persistence subsystem** with production-grade adapters and maintenance/query surfaces
  - `EctoSessionStore` adapter with migrations and schemas (supports PostgreSQL, SQLite via `Ecto.Adapters.SQLite3`)
  - `S3ArtifactStore` adapter for S3-compatible object storage
  - `CompositeSessionStore` adapter combining SessionStore + ArtifactStore
  - `QueryAPI` and `Maintenance` ports with Ecto implementations (`EctoQueryAPI`, `EctoMaintenance`)
  - Persistence modules: `EventPipeline`, `EventValidator`, `RetentionPolicy`, `ArtifactRegistry`
- **`flush/2` and `append_events/2` callbacks** on the `SessionStore` port
  - `flush/2` atomically persists final session/run state (and any queued events) in transactional backends like Ecto
  - `append_events/2` persists a batch of events with atomic sequence assignment (used by `EventPipeline.process_batch/3`)
  - Implemented in `EctoSessionStore`, `InMemorySessionStore`, and `CompositeSessionStore`
- **`EventBuilder` module** (`AgentSessionManager.Persistence.EventBuilder`) for pure event normalize/enrich/validate processing without persistence
- **`ExecutionState` module** (`AgentSessionManager.Persistence.ExecutionState`) for in-memory run state accumulation (session, run, events, provider metadata)
- **`OptionalDependency` module** for standardized error reporting when optional dependencies (Ecto, ExAws) are missing
- **`Runtime.ExitReasons` module** for shared adapter/store exit-reason classification across SessionManager + provider boundaries
- **SessionManager subsystem modules** for cleaner orchestration boundaries
  - `InputMessageNormalizer`
  - `ProviderMetadataCollector`
- **Top-level persistence convenience API** on `AgentSessionManager`
  - `session_store/1` for `SessionStore` refs (`pid` or `{Module, context}`)
  - `query_api/1` for `QueryAPI` refs
  - `maintenance/1` for `Maintenance` refs
- **Conditional compilation** for optional Ecto, AWS, and provider SDK dependencies
  - `EctoSessionStore`, `EctoQueryAPI`, `EctoMaintenance`, Ecto migrations/schemas wrapped in conditional blocks
  - `S3ArtifactStore.ExAwsClient` provides fallback when ExAws is missing
  - `ArtifactRegistry` Ecto-dependent metadata tracking wrapped with fallback logic
  - `AmpAdapter`, `ClaudeAdapter`, and `CodexAdapter` compile only when their SDK deps are available
  - Library can be used without Ecto, ExAws, or provider SDK dependencies installed
- **`SessionManager` store-failure hardening**
  - All `SessionStore` calls wrapped in `safe_store_call/2`
  - Store process exits converted to `:storage_connection_failed` errors
  - Prevents `SessionServer` execution tasks from crashing when store teardown races with failed-run finalization
- **`ProviderAdapter` error normalization**
  - `call_with_error/4` and `call_exit_error/4` for structured exit normalization
  - `:noproc`, `:timeout`, and unexpected exits normalized into `Core.Error` structs
  - `provider_unavailable` tolerance in `cancel_run` request path
- **`Core.Serialization` module** consolidating `atomize_keys/1` and `stringify_keys/1` across `EctoSessionStore` and `EctoQueryAPI`
- **Shared Ecto converters module** (`EctoSessionStore.Converters`) used by both store and query adapters for schema <-> core transformations
- **Ecto migrations** (V1 base schema, V2 provider/artifact fields, V3 foreign keys) and Ecto schemas for sessions, runs, and events
- **`Event` struct extensions**: `schema_version`, `provider`, `correlation_id` fields
- **`Session` struct extension**: `deleted_at` for soft-delete support
- **Persistence test hardening suites** for regression resistance
  - `ecto_session_store_concurrency_test.exs` (concurrent append/session consistency)
  - `session_store_contract_multi_impl_test.exs` (contract tests across InMemory + Ecto refs)
  - `ecto_session_store_migration_compat_test.exs` and `ecto_session_store_migration_down_test.exs` (migration prerequisite + rollback coverage)
- Persistence live examples: `sqlite_session_store_live.exs`, `ecto_session_store_live.exs`, `s3_artifact_store_live.exs`, `composite_store_live.exs`, `persistence_query.exs`, `persistence_maintenance.exs`, `persistence_multi_run.exs`, `persistence_live.exs`, `persistence_s3_minio.exs`
- **Approval gates and human-in-the-loop policy enforcement**
  - New `request_approval` policy action as a valid `on_violation` value, emitting `tool_approval_requested` events without automatically cancelling the run
  - Strictness hierarchy for policy stacking: `cancel` > `request_approval` > `warn`
  - Core event types for `tool_approval_requested`, `tool_approval_granted`, and `tool_approval_denied` with validation and persistence support
  - `cancel_for_approval/4` in `SessionManager` for streamlined run cancellation pending human review
  - `TranscriptBuilder` synthetic tool responses when a run is awaiting approval, reflecting the paused state in the transcript
  - Comprehensive tests for runtime enforcement and stacking, `approval_gates.exs` example, and updated policy enforcement guide
- **Interactive interrupt example** (`interactive_interrupt.exs`) demonstrating mid-stream run cancellation and follow-up prompts within the same session
- Case-insensitive tool name matching in `approval_gates.exs` policy rules (lowercase and title case variants)
- **Shell Runner** (`ShellAdapter` provider and `Workspace.Exec`)
  - `ShellAdapter` implements `ProviderAdapter` as a GenServer with `Task.Supervisor`-backed concurrent execution
  - Three input formats: string (shell-wrapped via `/bin/sh -c`), structured map (explicit command/args/cwd), and messages (compatibility extraction from user content)
  - Full canonical event sequence: `run_started`, `tool_call_started`, `tool_call_completed/failed`, `message_received`, `run_completed/failed/cancelled` with `provider: :shell` attribution
  - Security controls: `allowed_commands` and `denied_commands` lists with denylist-takes-precedence semantics
  - Configurable `success_exit_codes` for treating non-zero exits as success
  - Cancellation kills both the Elixir task and underlying OS process via pid
  - `Workspace.Exec` for low-level command execution via `Port.open` with timeout, output capture, max output bytes truncation, environment variables, and OS process management
  - `run_streaming/3` returns lazy `Stream.resource` for incremental output
  - `on_output` callback support in structured map input for streaming
  - Advertises `command_execution` and `streaming` capabilities
  - New guide: `guides/shell_runner.md`
  - New example: `shell_exec.exs` demonstrating mixed provider + shell execution
- **CodexAdapter `ItemStarted`/`ItemCompleted` event handling**
  - Emit `tool_call_started` and `tool_call_completed` events for Codex command execution, file change, and MCP tool call items
  - Normalize `CommandExecution` and `FileChange` item types to canonical tool event payloads
  - ID-based `agent_messages` tracking with `streamed_agent_message_ids` to avoid content duplication across multi-message turns
  - `active_tools` state preserves tool inputs during the call lifecycle
- **Ash Framework persistence integration** as an optional alternative to raw Ecto adapters
  - New Ash resources and domain for `asm_*` tables
  - New adapters: `AshSessionStore`, `AshQueryAPI`, and `AshMaintenance`
  - Atomic per-session sequence assignment via `AssignSequence`
  - Ash-focused tests, guide (`guides/ash_session_store.md`), and live example (`examples/ash_session_store.exs`)
- **PubSub integration** for real-time event broadcasting via Phoenix PubSub
  - `PubSubSink` rendering sink broadcasts events to configurable PubSub topics
  - `AgentSessionManager.PubSub` helper module with `event_callback/2` and `subscribe/2`
  - `AgentSessionManager.PubSub.Topic` for canonical topic naming (`asm:session:{id}`, `asm:session:{id}:run:{rid}`)
  - Optional dependency on `phoenix_pubsub ~> 2.1` with graceful stub fallback
- `AgentSessionManager.WorkflowBridge` module for workflow/DAG engine integration
- `WorkflowBridge.StepResult` normalized result type with routing signals
- `WorkflowBridge.ErrorClassification` for retry/failover/abort decisions
- `step_execute/3` supporting one-shot and multi-run execution modes
- `setup_workflow_session/3` and `complete_workflow_session/3` lifecycle helpers
- `classify_error/1` mapping ASM errors to workflow routing actions
- `examples/workflow_bridge.exs` live example
- `guides/workflow_bridge.md` integration guide
- **Secrets redaction for persisted events** (`EventRedactor` module)
  - Configurable pattern-based secret detection and `[REDACTED]` replacement
  - Integrates into `EventBuilder` pipeline between build and enrich steps
  - Default patterns for AWS keys, AI provider tokens, GitHub PATs, JWTs, passwords, connection strings, private keys, environment variables
  - Custom pattern support via application config or per-pipeline context override
  - `redact_map/2` public API for user callback and telemetry handler wrapping
  - Opt-in via `redaction_enabled: true` (default: disabled for backward compatibility)
  - Telemetry event `[:agent_session_manager, :persistence, :event_redacted]` emitted on redaction
  - Five new `Config` keys: `redaction_enabled`, `redaction_patterns`, `redaction_replacement`, `redaction_deep_scan`, `redaction_scan_metadata`
- **`StudioRenderer`** — CLI-grade interactive renderer for terminal display
  - Human-readable tool summaries instead of raw JSON output
  - Status symbols: `◐` (running), `✓` (success), `✗` (failure), `●` (info)
  - Three tool output modes: `:summary`, `:preview`, `:full`
  - Clean text streaming with indentation and visual phase separation
  - Automatic non-TTY fallback (no cursor control when piped)
  - `Studio.ANSI` shared utility module for colors, cursor control, and symbols
  - `Studio.ToolSummary` per-tool summarization for bash, Read, Write, Edit, Glob, Grep, Task, WebFetch, WebSearch
- New example: `rendering_studio.exs` demonstrating StudioRenderer with all three tool output modes
- New guide section: StudioRenderer in `guides/rendering.md`
- **`CostCalculator`** with model-aware pricing and USD cost tracking (`AgentSessionManager.Cost.CostCalculator`)
  - Three-tier model resolution: exact match, prefix match with date suffix stripping, provider default fallback
  - Cache token support for Claude prompt caching (`cache_read_tokens`, `cache_creation_tokens`)
  - `cost_usd` field added to `Run` struct with serialization support
  - `get_cost_summary/2` callback on `QueryAPI` with per-run aggregation (total, by_provider, by_model)
  - Policy `Runtime` model-aware rate resolution via `CostCalculator.resolve_rates/3`
  - `MigrationV4` adding `cost_usd` float column to `asm_runs` table
  - Cost display in `CompactRenderer`, `VerboseRenderer`, and `JSONLSink`
  - `SessionManager` finalization prefers SDK-provided `total_cost_usd`, falls back to `CostCalculator`
  - New guide: `guides/cost_tracking.md`
  - New example: `cost_tracking.exs`
- **`AgentSessionManager.Config` centralization** of all operational defaults
  - All library timeouts, buffer sizes, and limits moved into centralized Config with three-layer resolution (process-local, application env, hardcoded fallback)
  - New guide: Configuration Reference
- **`AgentSessionManager.Models`** central registry for model identifiers and pricing
  - Runtime model name, default provider model, and per-token pricing lookup
  - `AgentSessionManager.Test.Models` for test fixture management
  - New guide: Model Configuration

### Changed

- **`SessionStore` is the single execution persistence boundary** -- event persistence remains per-event via `append_event_with_sequence/2`, with `append_events/2` available for batch paths and `flush/2` used during finalization
- **`SessionStore` refs now support both `pid` and `{Module, context}` dispatch** -- Ecto-backed usage can call adapters directly (for example `{EctoSessionStore, Repo}`) instead of routing through a single GenServer
- **`QueryAPI` and `Maintenance` refactored to module-backed refs** -- `{EctoQueryAPI, Repo}` and `{EctoMaintenance, Repo}` replace dedicated GenServer adapters, removing process lifecycle overhead
- **`EventPipeline` processing** -- builds events via `EventBuilder`; `process/3` persists per-event with `append_event_with_sequence/2`, while `process_batch/3` persists via `append_events/2`
- **Session lifecycle event persistence unified through `EventPipeline`** so internal lifecycle emissions and adapter callback events use the same validation/persistence path
- **Session finalization integrates `ExecutionState`** for consistent in-memory accumulation and final flush behavior
- **Provider metadata extraction** no longer depends on run-scoped `SessionStore.get_events/3` read-back; metadata is captured from callback/result event data during execution
- **`ArtifactRegistry` decoupled from adapter schema modules** via behaviour-based injection to preserve persistence layering
- **`InMemorySessionStore` event appends moved to queue-based buffering** to avoid O(n) append overhead under load
- **`CompositeSessionStore` direct-call timeout handling** now propagates `wait_timeout_ms` and isolates artifact failures from session persistence paths
- `crypto.strong_rand_bytes` used for workspace artifact keys instead of `System.unique_integer`
- **Current-only contract cleanup** (backward-compatibility shims removed):
  - Boolean continuation value `true` is no longer accepted; use `:auto`, `:replay`, `:native`, or `false`
  - Adapter tool events emit canonical keys only: `tool_call_id`, `tool_name`, `tool_input`, `tool_output`; provider-native aliases (`call_id`, `tool_use_id`, `arguments`, `input`, `output`, `content`) removed
  - `TranscriptBuilder` and renderers consume canonical tool keys only; fallback chains through legacy keys removed
  - `Event.from_map/1` requires explicit `schema_version` (integer >= 1); `nil`/missing no longer defaults to 1
  - `QueryAPI` and `Maintenance` accept module-backed `{Module, context}` refs only; GenServer dispatch paths return `:validation_error`
  - `SessionServer.status/1` no longer includes the legacy `active_run_id` status field
  - Session provider metadata is stored under `session.metadata[:provider_sessions]` without top-level duplication; top-level `:provider_session_id` and `:model` keys are no longer merged
- **ClaudeAdapter refactoring**: removed `execute_with_mock_sdk` path and receive-based event stream processing (~300 lines); added stop_reason tracking through streaming context, `:cancelled` result subtype handling from SDK stream, and extracted `extract_usage_counts`, `extract_stop_reason`, `emit_success_events`, `maybe_emit_run_completed` helpers
- **`EventBuilder`** no longer duplicates provider into `event.metadata`; provider lives on `Event.provider` struct field only
- **`EventNormalizer`** removes type inference heuristics (content-key sniffing, status-based refinement, fuzzy type mappings); `resolve_type` validates against `Event.valid_type?/1` using canonical names only
- `MockSDK` gains `query/3` interface returning `Stream.resource` with `ClaudeAgentSDK.Message` emission, including tool_use content block handling and error scenarios
- `codex_sdk` dependency updated from path ref to `~> 0.8.0` hex package
- PubSub defaults are now configured per use (`PubSubSink` / `PubSub.event_callback`) and are no longer exposed as global `AgentSessionManager.Config` keys
- `FileSink` ANSI strip regex extended to also remove cursor control sequences (`\r`, `\e[2K`, `\e[NA`)
- Execution timeout propagated to underlying SDK options: Amp (`stream_timeout_ms`) and Claude (`timeout_ms`) with configurable fallback
- Unbounded/infinite timeout support across all adapters with 7-day (604,800,000 ms) emergency cap to prevent runaway processes
- Codex adapter `sdk_opts` selective merge filtering against target module keys (supports both atom and string keys)
- Codex adapter extracts confirmed model names and reasoning effort from thread metadata events
- Amp adapter includes model state in execution context
- Ash query filtering enhancements: `min_tokens` filter, `since`/`until` temporal filtering, multi-status filtering, strict limit validation, improved cursor pagination
- All adapters (Shell, Ecto, Ash) use dynamic configuration from `Config` module
- `RetentionPolicy` pulls defaults from central Config
- `ConcurrencyLimiter` uses configurable parallel session limits from Config
- `CostCalculator` uses centralized pricing table from `Models`
- `ClaudeAdapter` and examples use dynamic default model from `Models`
- Ash adapters use `expr` macro in query filters; large functions broken into focused helpers
- `WorkflowBridge` keyword list normalization improved for adapter options and continuation parameters
- Ash tests gated behind `RUN_ASH_TESTS` environment variable
- Provider adapters (`CodexAdapter`, `AmpAdapter`, `ClaudeAdapter`) now normalize provider failures into a stable `provider_error` payload and preserve provider-specific extras in `Error.details`
- Session/run failure paths now persist and emit structured provider diagnostics (`provider_error`, `details`) alongside legacy `error_message`
- Added shared `AgentSessionManager.Core.ProviderError` normalization to enforce the contract:
  - `provider`, `kind`, `message`, `exit_code`, `stderr`, `truncated?`
  - Truncation limits are configurable via `:error_text_max_bytes` and `:error_text_max_lines`

### Fixed

- **Cursor pagination correctness (C-1)** -- cursor tokens are decoded and applied via keyset filters with explicit ordering validation; invalid cursors return structured errors instead of silently repeating page 1
- **`delete_session/2` and hard-delete cascade safety (C-2, C-5)** -- session/run/event deletion paths are transactional and delete dependent rows deterministically to prevent orphaned records
- **Event persistence error handling (C-3)** -- `EventPipeline` persistence failures are surfaced to callers and SessionManager callback/store interactions are protected from teardown crashes
- **Ecto insert crash path (C-4)** -- bang inserts in GenServer call paths replaced with safe insert + rollback handling to avoid store process crashes
- **Migration prerequisite mismatch (C-6)** -- EctoSessionStore now fails fast when required V2 columns are missing, preventing runtime crashes from V1-only schemas
- **Maintenance correctness (M-1, M-2, M-9)** -- health checks use `max(sequence_number)`, retention age checks use `updated_at`, and protected prune event types include `run_started`/`run_completed`
- **Optional dependency error semantics (M-10)** -- missing optional dependencies now normalize to `:dependency_not_available` instead of generic storage failure codes
- **Composite direct call timeout behavior (M-8 scoped)** -- `CompositeSessionStore.get_events/3` correctly adjusts call timeout for long-poll options
- Event redaction now scans nested `provider_error` payloads (including `stderr`) on failure events (`:error_occurred`, `:run_failed`, `:session_failed`)

### Removed

- Persistence abstractions removed in favor of `SessionStore` + `flush/2`:
  - `AgentSessionManager.Ports.DurableStore`
  - `AgentSessionManager.Adapters.NoopStore`
  - `AgentSessionManager.Adapters.SessionStoreBridge`
- Raw `SQLiteSessionStore` replaced by `EctoSessionStore` + `ecto_sqlite3`
- Event emitter path removed; event build/validation/persistence flows through `EventBuilder` + `EventPipeline`

See `guides/migrating_to_v0.8.md` for migration details.

### Documentation

- Persistence guides: `persistence_overview.md`, `ecto_session_store.md`, `sqlite_session_store.md`, `s3_artifact_store.md`, `composite_store.md`, `event_schema_versioning.md`, `custom_persistence_guide.md`, `migrating_to_v0.8.md`
- Persistence module group and guides added to HexDocs configuration
- New guide: `guides/shell_runner.md` covering `Workspace.Exec` and `ShellAdapter` usage, input formats, configuration, event mapping, security controls, and mixed AI+shell workflows
- Update `guides/provider_adapters.md` with ShellAdapter section, event mapping table, and Shell Runner module group in HexDocs
- Update `README.md` with approval gate functionality, interactive interrupt example, and Shell Runner feature
- Update `examples/README.md` with `interactive_interrupt.exs`, `approval_gates.exs`, and `shell_exec.exs` entries
- Add `interactive_interrupt.exs` and `shell_exec.exs` to `run_all.sh` automated test suite
- Update `README.md` and persistence overview with per-event persistence and `flush/2` finalization details
- Document V2 migration prerequisites + V3 foreign-key migration expectations for SQLite and PostgreSQL flows
- Document cursor semantics/order requirements, SessionStore ref shapes (`pid` vs `{Module, context}`), and optional SDK dependency behavior
- Update `examples/README.md` with all persistence adapter and query/maintenance examples
- Rewrite `guides/event_schema_versioning.md` for strict-only contract (no backward-compatible defaults)
- Document structured `provider_error` propagation, stderr truncation limits, and failure-event payload semantics across `README.md`, `guides/error_handling.md`, `guides/events_and_streaming.md`, and related rendering/streaming guides
- Remove "backward compatible" / "legacy" language from all guides
- Update `guides/session_continuity.md`: remove boolean `true` documentation, simplify mode table
- Update `guides/provider_adapters.md`: remove alias emission notes, canonical keys only

## [0.7.0] - 2026-02-09

### Added

- **Generic rendering system** with pluggable Renderer x Sink architecture (`AgentSessionManager.Rendering`)
  - `Rendering.stream/2` orchestrator consumes any `Enumerable` of event maps, renders each event, and writes to all sinks simultaneously
  - Full lifecycle: init -> render loop -> finish -> flush -> close
- **`Renderer` behaviour** with three built-in implementations
  - `CompactRenderer` - single-line token format (`r+`, `r-`, `t+Name`, `t-Name`, `>>`, `tk:N/M`, `msg`, `!`, `?`) with optional ANSI color support via `:color` option
  - `VerboseRenderer` - line-by-line bracketed format (`[run_started]`, `[tool_call_started]`, etc.) with inline text streaming and labeled fields
  - `PassthroughRenderer` - no-op renderer returning empty iodata for every event, for use with programmatic sinks
- **`Sink` behaviour** with four built-in implementations
  - `TTYSink` - writes rendered iodata to a terminal device (`:stdio` default), preserving ANSI codes
  - `FileSink` - writes rendered output to a plain-text file with ANSI codes stripped; supports both `:path` (owns the file) and `:io` (pre-opened device, caller manages lifecycle) options
  - `JSONLSink` - writes events as JSON Lines with `:full` mode (all fields, ISO 8601 timestamps) and `:compact` mode (abbreviated type codes, millisecond epoch timestamps)
  - `CallbackSink` - forwards raw events and rendered iodata to a 2-arity callback function for programmatic processing
- **ANSI color support** in `CompactRenderer` with configurable `:color` option (default `true`)
- **`StreamSession`** one-shot streaming session lifecycle module
  - `StreamSession.start/1` replaces ~35 lines of hand-rolled boilerplate (store + adapter + task + Stream.resource + cleanup) with a single function call
  - Returns `{:ok, stream, close_fun, meta}` - a lazy event stream, idempotent close function, and metadata map
  - Automatic `InMemorySessionStore` creation when no store is provided
  - Adapter startup from `{Module, opts}` tuples; passes through existing pids/names without ownership
  - Ownership tracking: only terminates resources that StreamSession created
  - Configurable idle timeout (default 120s) and shutdown grace period (default 5s)
  - Error events emitted for adapter failures, task crashes, exceptions, and timeouts (never crashes the consumer)
  - Atomic idempotent close via `:atomics.compare_exchange`
- **`StreamSession.Supervisor`** convenience supervisor for production use
  - Starts `Task.Supervisor` and `DynamicSupervisor` for managed task and adapter lifecycle
  - Optional - StreamSession works without it using `Task.start_link` directly
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
  - Stores that do not support `wait_timeout_ms` ignore it and fall back to immediate return
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
  - `ArtifactStore.put/4`, `get/3`, `delete/3` API (opts optional)
  - Without an artifact store configured, patches are embedded directly
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
  - Adapters emit canonical keys only (`tool_call_id`, `tool_name`, `tool_input`, `tool_output`)
  - `normalize_tool_input/1` helper added to each adapter to guarantee `tool_input` is always a map
  - `find_tool_call/2` helper added to AmpAdapter to enrich `tool_call_completed` and `tool_call_failed` events with `tool_name` and `tool_input` from the originating tool call

### Documentation

- Update `guides/provider_adapters.md` with canonical tool event payload reference
- Update `guides/session_continuity.md` with canonical `tool_call_id` guidance
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
  - Canonical tool call ID handling via `tool_call_id`
  - `continuation: :auto` and `continuation_opts` support in `execute_run/4` and `run_once/4`
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

[Unreleased]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.7.0...v0.8.0
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
