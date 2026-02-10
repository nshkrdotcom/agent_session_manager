defmodule AgentSessionManager.Rendering.Renderers.PassthroughRenderer do
  @moduledoc """
  A no-op renderer that passes events through without formatting.

  Useful when sinks want to process raw events directly (e.g. a callback
  sink that forwards events to a consuming process, or a JSONL sink that
  serializes the event structs).

  Returns empty iodata for every event.
  """

  @behaviour AgentSessionManager.Rendering.Renderer

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def render_event(_event, state), do: {:ok, [], state}

  @impl true
  def finish(state), do: {:ok, [], state}
end
