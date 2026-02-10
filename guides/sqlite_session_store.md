# SQLite with EctoSessionStore

`AgentSessionManager` supports SQLite through
`AgentSessionManager.Adapters.EctoSessionStore` and `Ecto.Adapters.SQLite3`.

This replaces the legacy dedicated `SQLiteSessionStore` adapter with a single
transactional persistence implementation shared across PostgreSQL and SQLite.

## Prerequisites

Add Ecto and SQLite dependencies:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.8.0"},
    {:ecto_sql, "~> 3.12"},
    {:ecto_sqlite3, "~> 0.17"}
  ]
end
```

## Define a Repo

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.SQLite3
end
```

Configure it (for example in `config/runtime.exs`):

```elixir
config :my_app, MyApp.Repo,
  database: "priv/asm.sqlite3",
  pool_size: 5
```

## Run Migrations

`EctoSessionStore` ships migration modules you can invoke from your project
migrations.

```elixir
defmodule MyApp.Repo.Migrations.AddAgentSessionManager do
  use Ecto.Migration

  def up, do: AgentSessionManager.Adapters.EctoSessionStore.Migration.up()
  def down, do: AgentSessionManager.Adapters.EctoSessionStore.Migration.down()
end
```

```elixir
defmodule MyApp.Repo.Migrations.AddAgentSessionManagerV2 do
  use Ecto.Migration

  def up, do: AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.up()
  def down, do: AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.down()
end
```

Then run:

```bash
mix ecto.migrate
```

## Start the Store

```elixir
alias AgentSessionManager.Adapters.EctoSessionStore

{:ok, store} = EctoSessionStore.start_link(repo: MyApp.Repo)
```

With a registered name:

```elixir
{:ok, _store} = EctoSessionStore.start_link(repo: MyApp.Repo, name: :session_store)
```

## SessionStore Usage

```elixir
alias AgentSessionManager.Core.{Event, Run, Session}
alias AgentSessionManager.Ports.SessionStore

{:ok, session} = Session.new(%{agent_id: "assistant"})
:ok = SessionStore.save_session(store, session)

{:ok, run} = Run.new(%{session_id: session.id})
:ok = SessionStore.save_run(store, run)

{:ok, event} =
  Event.new(%{
    type: :message_received,
    session_id: session.id,
    run_id: run.id,
    data: %{content: "hello"}
  })

{:ok, persisted} = SessionStore.append_event_with_sequence(store, event)

{:ok, sessions} = SessionStore.list_sessions(store, status: :pending)
{:ok, events} = SessionStore.get_events(store, session.id, after: 0, limit: 50)
{:ok, latest_seq} = SessionStore.get_latest_sequence(store, session.id)
```

## Query and Maintenance

Query and maintenance are plain module adapters with explicit refs:

```elixir
alias AgentSessionManager.Adapters.{EctoMaintenance, EctoQueryAPI}
alias AgentSessionManager.Persistence.RetentionPolicy
alias AgentSessionManager.Ports.{Maintenance, QueryAPI}

query = {EctoQueryAPI, MyApp.Repo}
maint = {EctoMaintenance, MyApp.Repo}

{:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "assistant")
{:ok, usage} = QueryAPI.get_usage_summary(query)

policy = RetentionPolicy.new(max_completed_session_age_days: 90)
{:ok, report} = Maintenance.execute(maint, policy)
```

## Why this architecture

- One transactional implementation for all SQL backends
- Shared behavior/tests between SQLite and PostgreSQL
- No duplicated raw SQL store code to maintain
- Better long-term parity for `flush/2` finalization and `append_events/2` batch support
