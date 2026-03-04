defmodule ASM.Transport do
  @moduledoc """
  Transport contract for provider CLI I/O workers.
  """

  alias ASM.Error
  alias ASM.TaskSupport

  @default_call_timeout_ms 5_000

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary(), keyword()) :: :ok | {:error, Error.t()}
  @callback end_input(pid()) :: :ok | {:error, Error.t()}
  @callback interrupt(pid()) :: :ok | {:error, Error.t()}
  @callback close(pid()) :: :ok
  @callback stderr(pid()) :: String.t()
  @callback health(pid()) :: :healthy | :degraded | {:unhealthy, term()}

  @callback attach(pid(), pid()) :: {:ok, :attached} | {:error, term()}
  @callback detach(pid(), pid()) :: :ok | {:error, term()}
  @callback demand(pid(), pid(), pos_integer()) :: :ok

  @spec send_input(pid(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def send_input(transport_pid, input, opts \\ []) do
    send_input(transport_pid, input, opts, default_call_timeout_ms())
  end

  @spec send_input(pid(), binary(), keyword(), pos_integer()) :: :ok | {:error, Error.t()}
  def send_input(transport_pid, input, opts, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    case safe_call(transport_pid, {:send_input, input, opts}, timeout_ms) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:ok, {:error, reason}} ->
        {:error, transport_error("send failed: #{inspect(reason)}", reason)}

      {:ok, other} ->
        {:error, transport_error("send failed: #{inspect(other)}", other)}

      {:error, :timeout} ->
        {:error, timeout_error(:send_input, timeout_ms)}

      {:error, :not_connected} ->
        {:error, transport_error("transport not connected", :not_connected)}

      {:error, reason} ->
        {:error, transport_error("send failed: #{inspect(reason)}", reason)}
    end
  end

  @spec end_input(pid()) :: :ok | {:error, Error.t()}
  def end_input(transport_pid) do
    end_input(transport_pid, default_call_timeout_ms())
  end

  @spec end_input(pid(), pos_integer()) :: :ok | {:error, Error.t()}
  def end_input(transport_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case safe_call(transport_pid, :end_input, timeout_ms) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:ok, {:error, reason}} ->
        {:error, transport_error("end_input failed: #{inspect(reason)}", reason)}

      {:ok, other} ->
        {:error, transport_error("end_input failed: #{inspect(other)}", other)}

      {:error, :timeout} ->
        {:error, timeout_error(:end_input, timeout_ms)}

      {:error, :not_connected} ->
        {:error, transport_error("transport not connected", :not_connected)}

      {:error, reason} ->
        {:error, transport_error("end_input failed: #{inspect(reason)}", reason)}
    end
  end

  @spec interrupt(pid()) :: :ok | {:error, Error.t()}
  def interrupt(transport_pid), do: interrupt(transport_pid, default_call_timeout_ms())

  @spec interrupt(pid(), pos_integer()) :: :ok | {:error, Error.t()}
  def interrupt(transport_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case safe_call(transport_pid, :interrupt, timeout_ms) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:ok, {:error, reason}} ->
        {:error, transport_error("interrupt failed: #{inspect(reason)}", reason)}

      {:ok, _other} ->
        :ok

      {:error, :not_connected} ->
        :ok

      {:error, :timeout} ->
        {:error, timeout_error(:interrupt, timeout_ms)}

      {:error, reason} ->
        {:error, transport_error("interrupt failed: #{inspect(reason)}", reason)}
    end
  end

  @spec close(pid()) :: :ok
  def close(transport_pid), do: close(transport_pid, default_call_timeout_ms())

  @spec close(pid(), pos_integer()) :: :ok
  def close(transport_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case safe_call(transport_pid, :close, timeout_ms) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec stderr(pid()) :: String.t()
  def stderr(transport_pid) do
    case safe_call(transport_pid, :stderr, default_call_timeout_ms()) do
      {:ok, stderr} when is_binary(stderr) -> stderr
      _ -> ""
    end
  end

  @spec health(pid()) :: :healthy | :degraded | {:unhealthy, term()}
  def health(transport_pid) do
    case safe_call(transport_pid, :health, default_call_timeout_ms()) do
      {:ok, :healthy} ->
        :healthy

      {:ok, :degraded} ->
        :degraded

      {:ok, {:unhealthy, _reason} = unhealthy} ->
        unhealthy

      {:ok, _other} ->
        :degraded

      {:error, :not_connected} ->
        {:unhealthy, :not_connected}

      {:error, _reason} ->
        :degraded
    end
  end

  @spec attach(pid(), pid()) :: {:ok, :attached} | {:error, term()}
  def attach(transport_pid, run_pid),
    do: attach(transport_pid, run_pid, default_call_timeout_ms())

  @spec attach(pid(), pid(), pos_integer()) :: {:ok, :attached} | {:error, term()}
  def attach(transport_pid, run_pid, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    case safe_call(transport_pid, {:attach, run_pid}, timeout_ms) do
      {:ok, {:ok, :attached} = attached} ->
        attached

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_attach_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec detach(pid(), pid()) :: :ok | {:error, term()}
  def detach(transport_pid, run_pid),
    do: detach(transport_pid, run_pid, default_call_timeout_ms())

  @spec detach(pid(), pid(), pos_integer()) :: :ok | {:error, term()}
  def detach(transport_pid, run_pid, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    case safe_call(transport_pid, {:detach, run_pid}, timeout_ms) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_detach_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp safe_call(transport_pid, message, timeout_ms)
       when is_pid(transport_pid) and is_integer(timeout_ms) and timeout_ms > 0 do
    case TaskSupport.async_nolink(fn ->
           try do
             {:ok, GenServer.call(transport_pid, message, :infinity)}
           catch
             :exit, reason -> {:error, normalize_call_exit(reason)}
           end
         end) do
      {:ok, task} ->
        await_task_result(task, timeout_ms)

      {:error, reason} ->
        {:error, normalize_task_start_error(reason)}
    end
  end

  defp await_task_result(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, normalize_call_exit(reason)}

      nil ->
        {:error, :timeout}
    end
  end

  defp normalize_task_start_error(:noproc), do: :transport_stopped
  defp normalize_task_start_error({:task_start_failed, {:noproc, _}}), do: :transport_stopped
  defp normalize_task_start_error({:task_start_failed, :noproc}), do: :transport_stopped
  defp normalize_task_start_error(reason), do: {:call_exit, reason}

  defp normalize_call_exit({:noproc, _}), do: :not_connected
  defp normalize_call_exit(:noproc), do: :not_connected
  defp normalize_call_exit({:normal, _}), do: :not_connected
  defp normalize_call_exit({:shutdown, _}), do: :not_connected
  defp normalize_call_exit({:timeout, _}), do: :timeout
  defp normalize_call_exit(reason), do: {:call_exit, reason}

  defp default_call_timeout_ms do
    case Application.get_env(
           :agent_session_manager,
           :transport_call_timeout_ms,
           @default_call_timeout_ms
         ) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      _other ->
        @default_call_timeout_ms
    end
  end

  defp timeout_error(action, timeout_ms) do
    Error.new(:timeout, :transport, "#{action} timed out after #{timeout_ms}ms",
      cause: {:transport_call_timeout, action, timeout_ms}
    )
  end

  defp transport_error(message, cause) when is_binary(message) do
    Error.new(:transport_error, :transport, message, cause: cause)
  end
end
