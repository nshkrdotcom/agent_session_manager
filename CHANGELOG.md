# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/nshkrdotcom/agent_session_manager/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/agent_session_manager/releases/tag/v0.1.0
