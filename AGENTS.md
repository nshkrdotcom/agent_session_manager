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

## Live Provider Checks

For live provider checks, use `~/scripts/with_bash_secrets <command>`. It sources
`~/.bash/bash_secrets` and execs the command. Do not print secret values. Pipe
`LINEAR_API_KEY` via stdin for Linear examples. GitHub live examples use `gh auth`
or `GH_TOKEN`/`GITHUB_TOKEN` from the wrapper. Codex SDK examples use the existing
Codex/OpenAI machine auth through the wrapper. Live provider smoke is not product
acceptance unless it runs the product-owned Extravaganza command path.
