# Repository Guidelines

## Project Structure
- `lib/` contains public `ASM` modules and provider/session orchestration internals.
- `test/` contains ExUnit coverage and optional SDK stubs.
- `guides/`, `examples/`, `README.md`, and `CHANGELOG.md` must stay aligned with runtime and dependency behavior.
- `doc/` is generated output and should not be edited.

## Execution Plane Stack
- ASM sits above `cli_subprocess_core` and provider SDKs; do not expose raw `ExecutionPlane.*` transport internals as public API.
- Use `CliSubprocessCore` facades and mapped ASM envelopes for execution surfaces, transport errors, recovery, and events.
- Keep `cli_subprocess_core` dependency resolution publish-aware: local path deps for sibling development, Hex constraints for release builds.

## Gates
- Run `mix format`.
- Run `mix compile --warnings-as-errors`.
- Run `mix test`.
- Run `mix credo --strict`.
- Run `mix dialyzer`.
- Run `mix docs --warnings-as-errors`.
