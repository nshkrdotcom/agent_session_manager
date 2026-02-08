# Session Server Subscriptions (Feature 6)

`SessionServer` provides a subscription API for consuming **stored** session events while runs execute.

Subscribers receive:

```elixir
{:session_event, session_id, event}
```

Where `event` is an `AgentSessionManager.Core.Event` struct (including `sequence_number`).

## Subscribing

Call `subscribe/2` from the process that should receive messages:

```elixir
alias AgentSessionManager.Runtime.SessionServer

{:ok, ref} = SessionServer.subscribe(server, from_sequence: 0)
```

To stop receiving events:

```elixir
:ok = SessionServer.unsubscribe(server, ref)
```

## Filtering Options

`subscribe/2` supports these filters:

- `from_sequence` (default `0`)
- `run_id`
- `type`

Examples:

```elixir
# Only run start events
{:ok, _} = SessionServer.subscribe(server, type: :run_started)

# Only events for a specific run
{:ok, _} = SessionServer.subscribe(server, run_id: run_id)

# Only events after a durable cursor
{:ok, _} = SessionServer.subscribe(server, from_sequence: cursor)
```

## Cursor Semantics

Subscriptions are backed by `SessionStore.get_events/3` and sequence numbers assigned at append time.

Practical implications:

- `from_sequence` is durable and works across process restarts when your store preserves sequence numbers.
- Subscriptions can replay backlog (based on `from_sequence`) and continue with newly appended events.

## Notes on Runtime Internals

Feature 6 avoids expanding `Core.Event` types for runtime internals. Queue operations and runtime lifecycle are instead exposed via:

- existing session/run event types (persisted by `SessionManager`)
- telemetry events under the `[:agent_session_manager, :runtime, ...]` namespace

