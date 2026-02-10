defmodule AgentSessionManager.Rendering.Renderer do
  @moduledoc """
  Behaviour for rendering agent session events into human-readable output.

  A renderer transforms canonical event maps (as emitted by adapter event callbacks)
  into formatted text fragments. It does NOT decide where the text goes — that's the
  sink's job. This separation allows the same renderer to output to a terminal, a log
  file, or a WebSocket without changes.

  ## Event Format

  Renderers receive plain maps with at minimum:

      %{type: atom(), data: map(), ...}

  These are the canonical events emitted by adapters (ClaudeAdapter, CodexAdapter,
  AmpAdapter) via their `event_callback`. Common types include `:run_started`,
  `:message_streamed`, `:tool_call_started`, `:tool_call_completed`,
  `:run_completed`, `:error_occurred`, etc.

  ## Implementing a Renderer

      defmodule MyRenderer do
        @behaviour AgentSessionManager.Rendering.Renderer

        @impl true
        def init(opts), do: {:ok, %{mode: opts[:mode] || :default}}

        @impl true
        def render_event(event, state) do
          text = format(event)
          {:ok, text, state}
        end

        @impl true
        def finish(state), do: {:ok, "", state}
      end
  """

  @type state :: term()
  @type opts :: keyword()

  @doc """
  Initialize renderer state from options.
  """
  @callback init(opts()) :: {:ok, state()} | {:error, term()}

  @doc """
  Render a single event into a text fragment (possibly empty).

  Returns `{:ok, iodata, new_state}`. The iodata is forwarded to all sinks.
  Return empty iodata (`""` or `[]`) to suppress output for an event.
  """
  @callback render_event(event :: map(), state()) :: {:ok, iodata(), state()}

  @doc """
  Called when the stream ends. Return any final output (e.g. summary line).
  """
  @callback finish(state()) :: {:ok, iodata(), state()}
end
