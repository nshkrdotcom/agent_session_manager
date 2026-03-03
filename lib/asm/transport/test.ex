defmodule ASM.Transport.Test do
  @moduledoc """
  Test transport adapter that delegates lease/demand behavior to `ASM.Transport.Port`.
  """

  @behaviour ASM.Transport

  alias ASM.Transport.Port

  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Port.start_link(opts)

  @spec inject(pid(), map()) :: :ok
  def inject(pid, raw_map), do: Port.inject(pid, raw_map)

  @impl true
  def send_input(pid, input, opts), do: Port.send_input(pid, input, opts)

  @impl true
  def interrupt(pid), do: Port.interrupt(pid)

  @impl true
  def close(pid), do: Port.close(pid)

  @impl true
  def health(pid), do: Port.health(pid)

  @impl true
  def attach(pid, run_pid), do: Port.attach(pid, run_pid)

  @impl true
  def detach(pid, run_pid), do: Port.detach(pid, run_pid)

  @impl true
  def demand(pid, run_pid, n), do: Port.demand(pid, run_pid, n)
end
