# ASM (Agent Session Manager)

Lean, OTP-correct Elixir runtime for managing AI agent sessions across live CLI providers:

- Claude CLI
- Gemini CLI
- Codex CLI (exec mode)

This branch is a ground-up foundation rebuild focused on explicit ownership boundaries, deterministic replay semantics, and modular extension seams.

## Foundation Scope (v1)

- Session aggregate runtime (`ASM.Session.Server`)
- Per-run runtime (`ASM.Run.Server` + `ASM.Run.EventReducer`)
- Bounded lease-aware transport contract (`ASM.Transport.Port`)
- Provider contracts (resolver, command builders, parsers)
- Optional synchronous pipeline plugs
- Event-first in-memory store + replay (`ASM.Store.Memory`, `ASM.History`)
- Public facade (`ASM`) + stream helpers (`ASM.Stream`)
- Live examples for Claude/Gemini/Codex CLIs

## Install

```elixir
def deps do
  [
    {:agent_session_manager, path: "../agent_session_manager"}
  ]
end
```

## Public API

### Start/Stop a session

```elixir
{:ok, session} = ASM.start_session(provider: :claude)
:ok = ASM.stop_session(session)
```

### Stream a run

```elixir
stream = ASM.stream(session, "Reply with exactly: OK")

for event <- stream do
  IO.inspect(event.kind)
end
```

### Query and return final result

```elixir
{:ok, result} = ASM.query(session, "Say hello")
IO.inspect(result.text)

# Provider atom form (ephemeral session lifecycle)
{:ok, result2} = ASM.query(:gemini, "Say hello")
```

### Runtime control helpers

```elixir
ASM.health(session)
ASM.cost(session)
ASM.interrupt(session, run_id)
ASM.approve(session, approval_id, :allow)
```

## Live Examples

Run with real CLIs (no mocks):

```bash
mix run examples/live_claude_stream.exs -- "Reply with exactly: CLAUDE_OK"
mix run examples/live_gemini_stream.exs -- "Reply with exactly: GEMINI_OK"
mix run examples/live_codex_stream.exs -- "Reply with exactly: CODEX_OK"
mix run examples/live_multi_provider_smoke.exs
```

Environment knobs:

- `CLAUDE_CLI_PATH`, `GEMINI_CLI_PATH`, `CODEX_PATH` (optional explicit binaries)
- `ASM_PERMISSION_MODE` (`default`, `auto`, `bypass`, `plan`)
- `ASM_CLAUDE_MODEL`, `ASM_GEMINI_MODEL`, `ASM_CODEX_MODEL` (optional)

## Architecture Notes

- Per-session subtree strategy: `:rest_for_one`
  - `ASM.Session.TransportSupervisor`
  - `ASM.Run.Supervisor`
  - `ASM.Session.Server`
- Run workers are `restart: :temporary` to prevent restart loops on normal completion.
- Session server owns run queueing and approval index.
- Run server owns event fanout and lifecycle transitions via reducer.

## Quality Gates

Foundation baseline is expected to pass locally:

```bash
mix format
mix test
mix credo --strict
mix dialyzer
```

Current foundation baseline: green (`108 tests + 2 properties`, strict credo, dialyzer).
