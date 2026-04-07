defmodule ASM.Extensions.Rendering.Sinks.TTY do
  @moduledoc """
  Sink that writes rendered output to an IO device (default: `:stdio`).
  """

  @behaviour ASM.Extensions.Rendering.Sink

  alias ASM.Error

  @impl true
  def init(opts) do
    {:ok, %{device: Keyword.get(opts, :device, :stdio)}}
  end

  @impl true
  def write(iodata, state), do: write_iodata(iodata, state)

  @impl true
  def write_event(_event, iodata, state), do: write_iodata(iodata, state)

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def close(_state), do: :ok

  defp write_iodata(iodata, state) do
    IO.write(state.device, iodata)
    {:ok, state}
  rescue
    error ->
      {:error, Error.new(:unknown, :runtime, "tty sink write failed", cause: error), state}
  catch
    kind, reason ->
      {:error,
       Error.new(:unknown, :runtime, "tty sink write failed",
         cause: %{kind: kind, reason: reason}
       ), state}
  end
end
