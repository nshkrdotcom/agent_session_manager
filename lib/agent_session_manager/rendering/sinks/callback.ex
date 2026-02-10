defmodule AgentSessionManager.Rendering.Sinks.CallbackSink do
  @moduledoc """
  A sink that forwards events to a callback function.

  Useful for programmatic consumption of event streams — testing, forwarding
  to a GenServer, broadcasting via PubSub, etc.

  ## Options

    * `:callback` — A function `(event, iodata) -> term()`. Required.

  ## Example

      Rendering.stream(events,
        renderer: {PassthroughRenderer, []},
        sinks: [{CallbackSink, [callback: fn event, _iodata -> handle(event) end]}]
      )
  """

  @behaviour AgentSessionManager.Rendering.Sink

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :callback) do
      {:ok, callback} when is_function(callback, 2) ->
        {:ok, %{callback: callback}}

      {:ok, _} ->
        {:error, "callback must be a 2-arity function"}

      :error ->
        {:error, "callback option is required"}
    end
  end

  @impl true
  def write(_iodata, state), do: {:ok, state}

  @impl true
  def write_event(event, iodata, state) do
    state.callback.(event, iodata)
    {:ok, state}
  end

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def close(_state), do: :ok
end
