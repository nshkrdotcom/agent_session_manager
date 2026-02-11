# Rendering

The rendering system provides a pluggable pipeline for formatting and outputting agent session events. It separates _what_ events look like (renderers) from _where_ they go (sinks), allowing any combination.

## Architecture

```
Event Stream → Renderer → iodata → Sink 1 (TTY)
                                  → Sink 2 (File)
                                  → Sink 3 (JSONL)
                                  → Sink 4 (Callback)
```

A **renderer** transforms canonical event maps into formatted text (iodata). A **sink** writes that text to a destination. One renderer feeds multiple sinks simultaneously. The orchestrator (`Rendering.stream/2`) wires them together.

## Quick Start

```elixir
alias AgentSessionManager.Rendering
alias AgentSessionManager.Rendering.Renderers.CompactRenderer
alias AgentSessionManager.Rendering.Sinks.TTYSink

# Render a live event stream to the terminal
Rendering.stream(event_stream,
  renderer: {CompactRenderer, []},
  sinks: [{TTYSink, []}]
)
```

## Rendering.stream/2

The main entry point. Consumes an `Enumerable` of event maps, renders each event, and writes to all sinks.

```elixir
Rendering.stream(event_stream,
  renderer: {renderer_module, renderer_opts},
  sinks: [
    {sink_module_1, sink_opts_1},
    {sink_module_2, sink_opts_2}
  ]
)
```

Returns `:ok` on success or `{:error, reason}` on failure.

### Lifecycle

1. **Init** — `renderer.init(opts)` and `sink.init(opts)` for each sink
2. **Render loop** — For each event in the stream:
   - `renderer.render_event(event, state)` → `{:ok, iodata, new_state}`
   - `sink.write_event(event, iodata, state)` for each sink
3. **Finish** — `renderer.finish(state)` → final iodata written to sinks
4. **Cleanup** — `sink.flush(state)` then `sink.close(state)` for each sink

## Event Format

Renderers receive canonical event maps as emitted by adapter event callbacks. At minimum:

```elixir
%{type: atom(), data: map()}
```

Common fields include `:timestamp`, `:session_id`, `:run_id`, and `:provider`. See the [Events and Streaming](events_and_streaming.md) guide for the full event type reference.

### Event Types Handled by Renderers

| Event Type | Description | Key Data Fields |
|-----------|-------------|-----------------|
| `:run_started` | Run began | `model` |
| `:message_streamed` | Text content delta | `delta` or `content` |
| `:tool_call_started` | Tool invocation began | `tool_name`, `tool_input`, `tool_call_id` |
| `:tool_call_completed` | Tool invocation finished | `tool_name`, `tool_output` |
| `:token_usage_updated` | Token counts updated | `input_tokens`, `output_tokens` |
| `:message_received` | Complete message | `content`, `role` |
| `:run_completed` | Run finished | `stop_reason` |
| `:run_failed` | Run failed | `error_code`, `error_message` |
| `:run_cancelled` | Run cancelled | — |
| `:error_occurred` | Error during run | `error_code`, `error_message` |

Unknown event types are rendered as catch-all entries rather than dropped.

## Renderers

### CompactRenderer

Single-line token format with ANSI colors. Streams text and tool events inline.

```elixir
{CompactRenderer, color: true}
```

**Token legend:**

| Token | Meaning |
|-------|---------|
| `r+` | Run started |
| `r-` | Run completed (with stop reason suffix, e.g. `r-:end`) |
| `t+Name` | Tool call started |
| `t-Name` | Tool call completed |
| `>>` | Text stream follows |
| `tk:N/M` | Token usage (input/output) |
| `msg` | Complete message received |
| `!` | Error or failure |
| `?` | Unknown event type |

**Options:**

- `:color` — Enable ANSI color output. Default `true`.

**Example output:**

```
r+ sonnet >> Hello! I'll read that file for you. t+Read t-Read tr:defmodule Foo... >> The file contains... r-:end
12 events, 2 tools
```

### VerboseRenderer

Line-by-line bracketed format. Each structured event gets its own line with labeled fields. Streamed text is written inline between bracketed lines.

```elixir
{VerboseRenderer, []}
```

**Example output:**

```
[run_started] model=claude-sonnet-4-5-20250929 session_id=ses_123
Hello! I'll read that file for you.
[tool_call_started] name=Read id=tu_001 input={"path":"/foo.ex"}
[tool_call_completed] name=Read output=defmodule Foo...
The file contains a module definition.
[run_completed] stop_reason=end_turn
--- 8 events, 1 tools ---
```

### PassthroughRenderer

No-op renderer that returns empty iodata for every event. Use with sinks that process raw events directly (CallbackSink, JSONLSink).

```elixir
{PassthroughRenderer, []}
```

## Sinks

### TTYSink

Writes rendered output to a terminal device, preserving ANSI color codes.

```elixir
{TTYSink, device: :stdio}
```

**Options:**

- `:device` — IO device to write to. Default `:stdio`.

### FileSink

Writes rendered output to a plain-text log file with ANSI codes stripped.

```elixir
{FileSink, path: "session.log"}
```

**Options (one required):**

- `:path` — File path to write to. FileSink opens and owns the file.
- `:io` — Pre-opened IO device. FileSink writes to it but does **not** close it. Useful when you need to write a header before starting the rendering pipeline.

```elixir
# Pre-opened IO device example
{:ok, io} = File.open("session.log", [:write, :utf8])
IO.write(io, "Session started at #{DateTime.utc_now()}\n\n")

Rendering.stream(events,
  renderer: {CompactRenderer, []},
  sinks: [{FileSink, io: io}]
)

File.close(io)  # caller manages lifecycle
```

### JSONLSink

Writes events as JSON Lines (one JSON object per line). Ignores rendered text and serializes raw events directly.

```elixir
{JSONLSink, path: "events.jsonl", mode: :full}
```

**Options:**

- `:path` — File path to write to. Required.
- `:mode` — `:full` (default) or `:compact`.

**Full mode** preserves all event fields with ISO 8601 timestamps:

```json
{"ts":"2026-02-09T12:00:00Z","type":"run_started","data":{"model":"claude-sonnet-4-5-20250929"},"session_id":"ses_123","run_id":"run_456"}
```

**Compact mode** uses abbreviated type codes and millisecond epoch timestamps:

```json
{"t":1707464400123,"e":{"t":"rs","m":"sonnet-4-5-20250929"}}
{"t":1707464400200,"e":{"t":"ms","l":12}}
{"t":1707464400300,"e":{"t":"ts","n":"Read"}}
{"t":1707464400400,"e":{"t":"tc","n":"Read","l":245}}
{"t":1707464400500,"e":{"t":"rc","sr":"end"}}
```

| Compact Code | Full Type |
|-------------|-----------|
| `rs` | `run_started` |
| `ms` | `message_streamed` |
| `ts` | `tool_call_started` |
| `tc` | `tool_call_completed` |
| `tu` | `token_usage_updated` |
| `mr` | `message_received` |
| `rc` | `run_completed` |
| `rf` | `run_failed` |
| `rx` | `run_cancelled` |
| `er` | `error_occurred` |

### CallbackSink

Forwards raw events to a callback function. Use for programmatic event processing — aggregation, forwarding to GenServer, broadcasting via PubSub.

```elixir
{CallbackSink, callback: fn event, _iodata -> handle(event) end}
```

**Options:**

- `:callback` — A 2-arity function `(event, iodata) -> term()`. Required.

## Multi-Sink Pipelines

The rendering system's power comes from combining multiple sinks in a single pipeline. All sinks receive every event simultaneously:

```elixir
alias AgentSessionManager.Rendering
alias AgentSessionManager.Rendering.Renderers.CompactRenderer
alias AgentSessionManager.Rendering.Sinks.{TTYSink, FileSink, JSONLSink, CallbackSink}

{:ok, log_io} = File.open("session.log", [:write, :utf8])
IO.write(log_io, "=== Session Log ===\n\n")

event_count = :counters.new(1, [:atomics])

Rendering.stream(event_stream,
  renderer: {CompactRenderer, []},
  sinks: [
    {TTYSink, []},
    {FileSink, io: log_io},
    {JSONLSink, path: "events.jsonl", mode: :full},
    {JSONLSink, path: "events-compact.jsonl", mode: :compact},
    {CallbackSink, callback: fn _event, _iodata ->
      :counters.add(event_count, 1, 1)
    end}
  ]
)

File.close(log_io)
IO.puts("Processed #{:counters.get(event_count, 1)} events")
```

## Writing a Custom Renderer

Implement the `AgentSessionManager.Rendering.Renderer` behaviour:

```elixir
defmodule MyApp.MarkdownRenderer do
  @behaviour AgentSessionManager.Rendering.Renderer

  @impl true
  def init(_opts), do: {:ok, %{events: 0}}

  @impl true
  def render_event(%{type: :run_started, data: data}, state) do
    {:ok, "## Run Started\n\nModel: `#{data[:model]}`\n\n", %{state | events: state.events + 1}}
  end

  def render_event(%{type: :message_streamed, data: data}, state) do
    {:ok, data[:delta] || "", %{state | events: state.events + 1}}
  end

  def render_event(%{type: :tool_call_started, data: data}, state) do
    {:ok, "\n\n### Tool: #{data[:tool_name]}\n\n", %{state | events: state.events + 1}}
  end

  def render_event(_event, state) do
    {:ok, "", %{state | events: state.events + 1}}
  end

  @impl true
  def finish(state) do
    {:ok, "\n\n---\n_#{state.events} events processed_\n", state}
  end
end
```

## Writing a Custom Sink

### PubSubSink (Built-in)

ASM now ships a built-in `AgentSessionManager.Rendering.Sinks.PubSubSink`.
It broadcasts events via Phoenix PubSub and ignores rendered text unless
`include_iodata: true` is set.

Requires the optional `phoenix_pubsub` dependency:

```elixir
# mix.exs
{:phoenix_pubsub, "~> 2.1"}
```

```elixir
alias AgentSessionManager.Rendering.Sinks.PubSubSink

# Broadcast to per-session topics
{PubSubSink, pubsub: MyApp.PubSub, scope: :session}

# Broadcast to a static topic
{PubSubSink, pubsub: MyApp.PubSub, topic: "agent:events"}

# Dynamic topics (single or multi-topic)
{PubSubSink, pubsub: MyApp.PubSub, topic_fn: fn event ->
  alias AgentSessionManager.PubSub.Topic
  [
    Topic.build_session_topic("asm", event[:session_id]),
    Topic.build_run_topic("asm", event[:session_id], event[:run_id])
  ]
end}
```

Subscribers receive `{:asm_event, session_id, event}` by default.

See the [PubSub Integration guide](pubsub_integration.md) for full documentation,
including the event-callback bridge for non-rendering usage.

### Before (custom)

If you need a custom sink for non-standard behavior, implement the
`AgentSessionManager.Rendering.Sink` behaviour directly:

```elixir
defmodule MyApp.PubSubSink do
  @behaviour AgentSessionManager.Rendering.Sink

  @impl true
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    {:ok, %{topic: topic}}
  end

  @impl true
  def write(_iodata, state), do: {:ok, state}

  @impl true
  def write_event(event, _iodata, state) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, state.topic, {:agent_event, event})
    {:ok, state}
  end

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def close(_state), do: :ok
end
```

## Integration with Event Streams

`Rendering.stream/2` accepts any `Enumerable`. In practice, event streams come from adapter execution via `SessionManager.run_once/4` using an event callback and `Stream.resource`:

```elixir
defp build_event_stream(store, adapter, prompt) do
  parent = self()
  ref = make_ref()
  callback = fn event -> send(parent, {ref, :event, event}) end

  Task.start(fn ->
    result = SessionManager.run_once(store, adapter,
      %{messages: [%{role: "user", content: prompt}]},
      event_callback: callback)
    send(parent, {ref, :done, result})
  end)

  Stream.resource(
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
end
```

See the [rendering examples](live_examples.md) for complete runnable scripts using live providers.
