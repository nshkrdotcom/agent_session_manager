# StreamSession

StreamSession provides a one-shot streaming session lifecycle that replaces ~35 lines of hand-rolled boilerplate with a single function call. It handles store creation, adapter startup, task launch, lazy event streaming, error handling, and cleanup.

## Quick Start

```elixir
alias AgentSessionManager.Adapters.ClaudeAdapter
alias AgentSessionManager.StreamSession

{:ok, stream, close_fun, meta} =
  StreamSession.start(
    adapter: {ClaudeAdapter, []},
    input: %{messages: [%{role: "user", content: "Hello!"}]}
  )

stream
|> Stream.each(&IO.inspect/1)
|> Stream.run()

close_fun.()
```

That's it. StreamSession automatically:

- Starts an `InMemorySessionStore` (unless you provide your own)
- Starts the adapter from the `{Module, opts}` tuple
- Launches a task that calls `SessionManager.run_once/4` with event bridging
- Returns a lazy `Stream.resource` that yields events as they arrive
- Provides an idempotent `close_fun` for cleanup

## Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `:adapter` | Yes | - | `{AdapterModule, opts}` tuple, pid, or registered name |
| `:input` | Yes | - | Input map for `SessionManager.run_once/4` |
| `:store` | No | `InMemorySessionStore` | Pid or name of an existing `SessionStore` |
| `:agent_id` | No | `nil` | Agent identifier forwarded to `run_once/4` |
| `:run_opts` | No | `[]` | Additional keyword opts forwarded to `run_once/4` |
| `:idle_timeout` | No | `120_000` | Stream idle timeout in milliseconds |
| `:shutdown_timeout` | No | `5_000` | Task shutdown grace period in milliseconds |

## Using with Existing Store or Adapter

If you already have a running store or adapter, pass its pid directly. StreamSession will use it but **will not terminate it** on close:

```elixir
{:ok, store} = InMemorySessionStore.start_link([])
{:ok, adapter} = ClaudeAdapter.start_link([])

{:ok, stream, close_fun, _meta} =
  StreamSession.start(
    store: store,
    adapter: adapter,
    input: %{messages: [%{role: "user", content: "Hello!"}]}
  )

Enum.to_list(stream)
close_fun.()

# Both store and adapter are still alive
Process.alive?(store)    #=> true
Process.alive?(adapter)  #=> true
```

## Using with the Rendering Pipeline

StreamSession pairs naturally with the Rendering system:

```elixir
alias AgentSessionManager.Rendering
alias AgentSessionManager.Rendering.Renderers.CompactRenderer
alias AgentSessionManager.Rendering.Sinks.TTYSink

{:ok, stream, close_fun, _meta} =
  StreamSession.start(
    adapter: {ClaudeAdapter, []},
    input: %{messages: [%{role: "user", content: "Explain OTP."}]}
  )

Rendering.stream(stream,
  renderer: {CompactRenderer, [color: true]},
  sinks: [{TTYSink, []}]
)

close_fun.()
```

## Error Handling

When the adapter or task fails, the stream emits an `%{type: :error_occurred}` event instead of crashing the consumer:

```elixir
{:ok, stream, close_fun, _meta} = StreamSession.start(...)

events = Enum.to_list(stream)
close_fun.()

errors = Enum.filter(events, &(&1.type == :error_occurred))
# [%{
#   type: :error_occurred,
#   data: %{
#     error_message: "...",
#     provider_error: %{provider: :codex, kind: :transport_exit, stderr: "..."}
#   }
# }]
```

Error events are emitted for:
- Adapter errors (`AgentSessionManager.Core.Error` structs)
- Task crashes (`:shutdown`, `:killed`, or arbitrary crash reasons)
- Exceptions raised during `run_once`
- Idle timeouts (no events received within `:idle_timeout`)

## Supervision

For production use, add `AgentSessionManager.StreamSession.Supervisor` to your supervision tree:

```elixir
children = [
  AgentSessionManager.StreamSession.Supervisor,
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

This starts a `Task.Supervisor` and `DynamicSupervisor` that StreamSession can use for managed lifecycle. StreamSession works without the supervisor (using `Task.start_link` directly), but supervised mode provides better fault isolation.

## Before and After

### Before (hand-rolled, ~35 lines)

```elixir
{:ok, store} <- InMemorySessionStore.start_link([])
{:ok, adapter} <- ClaudeAdapter.start_link([])

parent = self()
ref = make_ref()
callback = fn event -> send(parent, {ref, :event, event}) end

Task.start(fn ->
  result = SessionManager.run_once(store, adapter, input, event_callback: callback)
  send(parent, {ref, :done, result})
end)

stream = Stream.resource(
  fn -> :running end,
  fn
    :done -> {:halt, :done}
    :running ->
      receive do
        {^ref, :event, event} -> {[event], :running}
        {^ref, :done, _result} -> {:halt, :done}
      after
        120_000 -> {:halt, :done}
      end
  end,
  fn _ -> :ok end
)

# Use stream...
# Manual cleanup of store, adapter, task...
```

### After (StreamSession, 3 lines)

```elixir
{:ok, stream, close_fun, _meta} =
  StreamSession.start(
    adapter: {ClaudeAdapter, []},
    input: %{messages: [%{role: "user", content: "Hello!"}]}
  )

# Use stream...
close_fun.()
```
