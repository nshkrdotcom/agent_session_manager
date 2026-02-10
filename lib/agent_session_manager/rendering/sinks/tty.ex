defmodule AgentSessionManager.Rendering.Sinks.TTYSink do
  @moduledoc """
  A sink that writes rendered output to a terminal device.

  Writes iodata directly to the configured IO device, preserving ANSI
  color codes for terminal display.

  ## Options

    * `:device` — The IO device to write to. Default `:stdio`.
  """

  @behaviour AgentSessionManager.Rendering.Sink

  @impl true
  def init(opts) do
    device = Keyword.get(opts, :device, :stdio)
    {:ok, %{device: device}}
  end

  @impl true
  def write(iodata, state) do
    IO.write(state.device, iodata)
    {:ok, state}
  end

  @impl true
  def write_event(_event, iodata, state) do
    IO.write(state.device, iodata)
    {:ok, state}
  end

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def close(_state), do: :ok
end
