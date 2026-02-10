# Migrating to v0.8

This guide summarizes the breaking changes between v0.7 and v0.8 and the
required updates for custom persistence integrations.

## Breaking Changes

- **Removed modules**: `DurableStore` port, `NoopStore` adapter,
  `SessionStoreBridge` adapter, and the legacy raw `SQLiteSessionStore`.
- **`SessionStore` new callbacks**: `append_events/2` and `flush/2` are now
  required by the port.
- **Event pipeline rename**: `EventEmitter` was renamed to `EventBuilder`.
- **Query/Maintenance refs**: `EctoQueryAPI` and `EctoMaintenance` are now
  module-backed refs (`{Module, Repo}`), not dedicated GenServers.
- **Optional deps**: Ecto and ExAws are now optional dependencies; adapters are
  conditionally compiled.

## Required Updates for Custom Session Stores

### 1. Implement `append_events/2`

`EventPipeline.process_batch/3` persists batches via `append_events/2`. If your
store does not support true batch writes, call your single-event append in a
loop, but keep ordering and idempotency guarantees.

### 2. Implement `flush/2`

`SessionManager` calls `flush/2` at run finalization to persist the final
session/run state (and any buffered events) atomically. If your backend supports
transactions, wrap the full write in one. At minimum, ensure all three
components are persisted and failures are surfaced as `{:error, %Error{}}`.

Expected payload shape:

```elixir
%{
  session: %Session{},
  run: %Run{},
  events: [%Event{}],
  provider_metadata: %{}
}
```

### 3. Verify sequencing and idempotency

`append_event_with_sequence/2` and `get_latest_sequence/2` remain required. If
you changed sequencing in v0.7, re-run the contract tests in
`test/agent_session_manager/ports/session_store_contract_test.exs`.

## Ecto Users

- Apply the V2 migration (`MigrationV2`) for provider fields, soft delete, and
  artifact metadata tables.
- Replace GenServer usage with module-backed refs:

```elixir
query = {EctoQueryAPI, MyApp.Repo}
maint = {EctoMaintenance, MyApp.Repo}
```

## Optional Dependencies

If you use Ecto-backed stores or S3 artifacts, ensure the corresponding deps
are present in your `mix.exs`. Without them, those adapters compile to stubs
that return a structured missing-dependency error.
