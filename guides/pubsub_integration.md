# PubSub Integration

AgentSessionManager provides first-class PubSub support for both event paths:

- Rendering pipeline path via `AgentSessionManager.Rendering.Sinks.PubSubSink`
- SessionManager callback path via `AgentSessionManager.PubSub.event_callback/2`

Use this when you need real-time fanout to multiple consumers (LiveView, audit workers, approval services).

## Installation

Add `phoenix_pubsub` as an optional dependency:

```elixir
# mix.exs
{:phoenix_pubsub, "~> 2.1", optional: true}
```

## PubSubSink (Rendering Pipeline)

`PubSubSink` implements the rendering `Sink` behaviour and broadcasts each event from `write_event/3`.
`write/2` is a no-op (rendered text is ignored unless included explicitly).

```elixir
alias AgentSessionManager.Rendering
alias AgentSessionManager.Rendering.Renderers.PassthroughRenderer
alias AgentSessionManager.Rendering.Sinks.PubSubSink

Rendering.stream(event_stream,
  renderer: {PassthroughRenderer, []},
  sinks: [
    {PubSubSink, [pubsub: MyApp.PubSub, scope: :session]}
  ]
)
```

### Options

- `:pubsub` (required): PubSub server name/module
- `:topic`: static topic (mutually exclusive with `:topic_fn`)
- `:topic_fn`: `fn event -> topic | [topics] end`
- `:prefix`: topic prefix, default `"asm"`
- `:scope`: `:session | :run | :type`, default `:session`
- `:message_wrapper`: wrapper atom, default `:asm_event`
- `:include_iodata`: include rendered iodata in message, default `false`
- `:dispatcher`: dispatcher module (defaults to `Phoenix.PubSub`, useful for tests)

### Message format

Default:

```elixir
{:asm_event, session_id, event}
```

With `include_iodata: true`:

```elixir
{:asm_event, session_id, event, iodata}
```

## Event Callback Bridge

When you are using `SessionManager.execute_run/4` or `SessionManager.run_once/4` directly, you can broadcast from the callback chain without rendering:

```elixir
alias AgentSessionManager.PubSub, as: ASMPubSub

callback = ASMPubSub.event_callback(MyApp.PubSub, scope: :session)

{:ok, _result} =
  AgentSessionManager.SessionManager.run_once(store, adapter, input,
    event_callback: callback
  )
```

Use `topic: "my:topic"` for a static topic, or `prefix`/`scope` for canonical scoped topics.

## Subscribing

Use `AgentSessionManager.PubSub.subscribe/2` for canonical topic subscription:

```elixir
alias AgentSessionManager.PubSub, as: ASMPubSub

:ok = ASMPubSub.subscribe(MyApp.PubSub, session_id: session_id)
:ok = ASMPubSub.subscribe(MyApp.PubSub, session_id: session_id, run_id: run_id)
:ok = ASMPubSub.subscribe(MyApp.PubSub, topic: "custom:topic")
```

## Topic Naming Convention

`AgentSessionManager.PubSub.Topic` provides canonical topic builders:

- `asm:session:{session_id}`
- `asm:session:{session_id}:run:{run_id}`
- `asm:session:{session_id}:type:{event_type}`

```elixir
alias AgentSessionManager.PubSub.Topic

Topic.build_session_topic("asm", session_id)
Topic.build_run_topic("asm", session_id, run_id)
Topic.build_type_topic("asm", session_id, :tool_call_started)
```

## LiveView Integration

```elixir
defmodule MyAppWeb.SessionLive do
  use MyAppWeb, :live_view

  alias AgentSessionManager.PubSub, as: ASMPubSub

  def mount(%{"session_id" => session_id}, _session, socket) do
    if connected?(socket) do
      ASMPubSub.subscribe(MyApp.PubSub, session_id: session_id)
    end

    {:ok, assign(socket, session_id: session_id, events: [])}
  end

  def handle_info({:asm_event, session_id, event}, socket) do
    socket =
      socket
      |> assign(:session_id, session_id)
      |> update(:events, fn events -> [event | events] end)

    {:noreply, socket}
  end
end
```

## Composing Callbacks

Compose PubSub broadcasting with custom callback logic:

```elixir
pubsub_cb = AgentSessionManager.PubSub.event_callback(MyApp.PubSub)

combined_cb = fn event ->
  pubsub_cb.(event)
  MyApp.EventLog.append(event)
end

AgentSessionManager.SessionManager.execute_run(store, adapter, run_id,
  event_callback: combined_cb
)
```

## Migration from Custom PubSubSink

If you previously had a custom sink module, replace it with the built-in sink:

```elixir
# Before
sinks: [{MyApp.PubSubSink, [topic: "agent:events"]}]

# After
sinks: [{AgentSessionManager.Rendering.Sinks.PubSubSink, [pubsub: MyApp.PubSub, topic: "agent:events"]}]
```

If your consumers match on a different wrapper atom, set `message_wrapper:` for compatibility.
