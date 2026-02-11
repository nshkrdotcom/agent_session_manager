# Ash SessionStore

This guide shows how to use AgentSessionManager (ASM) with Ash Framework and AshPostgres.

## Overview

`AshSessionStore`, `AshQueryAPI`, and `AshMaintenance` are optional Ash-based adapters that implement the same persistence ports as the Ecto adapters. They write to the same `asm_*` tables, so Ecto and Ash paths can share data.

## Prerequisites

- PostgreSQL
- ASM migrations applied:
  - `AgentSessionManager.Adapters.EctoSessionStore.Migration`
- Optional deps in `mix.exs`:

```elixir
{:ash, "~> 3.0", optional: true}
{:ash_postgres, "~> 2.0", optional: true}
```

## Setup

1. Configure an AshPostgres repo and set ASM Ash repo config:

```elixir
config :agent_session_manager, MyApp.AshRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "my_app"

config :agent_session_manager, :ash_repo, MyApp.AshRepo
```

2. Create an Ash domain that includes ASM resources:

```elixir
defmodule MyApp.AgentSessions do
  use Ash.Domain

  resources do
    resource AgentSessionManager.Ash.Resources.Session
    resource AgentSessionManager.Ash.Resources.Run
    resource AgentSessionManager.Ash.Resources.Event
    resource AgentSessionManager.Ash.Resources.SessionSequence
    resource AgentSessionManager.Ash.Resources.Artifact
  end
end
```

3. Build tuple refs used by ASM ports:

```elixir
store = {AgentSessionManager.Ash.Adapters.AshSessionStore, MyApp.AgentSessions}
query = {AgentSessionManager.Ash.Adapters.AshQueryAPI, MyApp.AgentSessions}
maint = {AgentSessionManager.Ash.Adapters.AshMaintenance, MyApp.AgentSessions}
```

## Usage

```elixir
alias AgentSessionManager.Core.{Session, Run, Event}
alias AgentSessionManager.Ports.{SessionStore, QueryAPI, Maintenance}
alias AgentSessionManager.Persistence.RetentionPolicy

{:ok, session} = Session.new(%{agent_id: "agent-1"})
:ok = SessionStore.save_session(store, session)

{:ok, run} = Run.new(%{session_id: session.id})
:ok = SessionStore.save_run(store, run)

{:ok, event} = Event.new(%{type: :run_started, session_id: session.id, run_id: run.id})
{:ok, _stored} = SessionStore.append_event_with_sequence(store, event)

{:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "agent-1")

policy = RetentionPolicy.new(max_completed_session_age_days: 90)
{:ok, report} = Maintenance.execute(maint, policy)
```

## Direct Ash Access

You can query ASM data directly through Ash resources:

```elixir
AgentSessionManager.Ash.Resources.Event
|> Ash.Query.filter(session_id == ^session_id)
|> Ash.Query.sort(sequence_number: :asc)
|> Ash.read!(domain: MyApp.AgentSessions)
```

## Migrating From EctoSessionStore

1. Keep existing tables and migrations.
2. Define Ash domain/resources as above.
3. Swap refs:
   - from `{EctoSessionStore, MyApp.Repo}`
   - to `{AshSessionStore, MyApp.AgentSessions}`
4. Keep the same `SessionStore`, `QueryAPI`, and `Maintenance` port calls.

## Architecture Notes

- Same tables and data format as Ecto path (status stored as strings, map keys stringified in DB).
- Sequence assignment uses atomic upsert in `asm_session_sequences`.
- Optional dependency fallback modules return `:dependency_not_available` errors when Ash is not installed.
