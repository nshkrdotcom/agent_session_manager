defmodule ASM.Transport do
  @moduledoc """
  Transport contract for provider CLI I/O workers.
  """

  alias ASM.Error

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary(), keyword()) :: :ok | {:error, Error.t()}
  @callback interrupt(pid()) :: :ok | {:error, Error.t()}
  @callback close(pid()) :: :ok
  @callback health(pid()) :: :healthy | :degraded | {:unhealthy, term()}

  @callback attach(pid(), pid()) :: {:ok, :attached} | {:error, :busy}
  @callback detach(pid(), pid()) :: :ok | {:error, :not_leasee}
  @callback demand(pid(), pid(), pos_integer()) :: :ok

  @spec send_input(pid(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def send_input(transport_pid, input, opts \\ []),
    do: GenServer.call(transport_pid, {:send_input, input, opts})

  @spec send_input(pid(), binary(), keyword(), pos_integer()) :: :ok | {:error, Error.t()}
  def send_input(transport_pid, input, opts, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(transport_pid, {:send_input, input, opts}, timeout_ms)
  end

  @spec interrupt(pid()) :: :ok | {:error, Error.t()}
  def interrupt(transport_pid), do: GenServer.call(transport_pid, :interrupt)

  @spec interrupt(pid(), pos_integer()) :: :ok | {:error, Error.t()}
  def interrupt(transport_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(transport_pid, :interrupt, timeout_ms)
  end

  @spec close(pid()) :: :ok
  def close(transport_pid), do: GenServer.call(transport_pid, :close)

  @spec close(pid(), pos_integer()) :: :ok
  def close(transport_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(transport_pid, :close, timeout_ms)
  end

  @spec health(pid()) :: :healthy | :degraded | {:unhealthy, term()}
  def health(transport_pid), do: GenServer.call(transport_pid, :health)

  @spec attach(pid(), pid()) :: {:ok, :attached} | {:error, :busy}
  def attach(transport_pid, run_pid), do: GenServer.call(transport_pid, {:attach, run_pid})

  @spec attach(pid(), pid(), pos_integer()) :: {:ok, :attached} | {:error, :busy}
  def attach(transport_pid, run_pid, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(transport_pid, {:attach, run_pid}, timeout_ms)
  end

  @spec detach(pid(), pid()) :: :ok | {:error, :not_leasee}
  def detach(transport_pid, run_pid), do: GenServer.call(transport_pid, {:detach, run_pid})

  @spec detach(pid(), pid(), pos_integer()) :: :ok | {:error, :not_leasee}
  def detach(transport_pid, run_pid, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(transport_pid, {:detach, run_pid}, timeout_ms)
  end

  @spec demand(pid(), pid(), pos_integer()) :: :ok
  def demand(transport_pid, run_pid, n \\ 1) when is_pid(run_pid) and n > 0 do
    GenServer.cast(transport_pid, {:demand, run_pid, n})
    :ok
  end

  @spec notify_message(pid(), map()) :: :ok
  def notify_message(run_pid, raw_map) do
    send(run_pid, {:transport_message, raw_map})
    :ok
  end

  @spec notify_error(pid(), term()) :: :ok
  def notify_error(run_pid, reason) do
    send(run_pid, {:transport_error, reason})
    :ok
  end

  @spec notify_exit(pid(), integer(), [String.t()]) :: :ok
  def notify_exit(run_pid, status, diagnostics \\ []) do
    send(run_pid, {:transport_exit, status, diagnostics})
    :ok
  end
end
