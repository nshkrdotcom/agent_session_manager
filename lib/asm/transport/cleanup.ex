defmodule ASM.Transport.Cleanup do
  @moduledoc false

  alias ASM.ProcessSupport
  alias ASM.Transport

  @default_close_grace_ms 2_000
  @default_shutdown_grace_ms 250
  @default_kill_grace_ms 250

  @spec close(pid(), keyword()) :: :ok
  def close(pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    close_fun = Keyword.get(opts, :close_fun, &Transport.close/1)
    close_grace_ms = Keyword.get(opts, :close_grace_ms, @default_close_grace_ms)
    shutdown_grace_ms = Keyword.get(opts, :shutdown_grace_ms, @default_shutdown_grace_ms)
    kill_grace_ms = Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms)
    monitor_ref = Keyword.get(opts, :monitor_ref, Process.monitor(pid))

    _ = safe_close(close_fun, pid)
    await_down_or_shutdown(monitor_ref, pid, close_grace_ms, shutdown_grace_ms, kill_grace_ms)
  end

  defp await_down_or_shutdown(ref, pid, close_grace_ms, shutdown_grace_ms, kill_grace_ms) do
    case ProcessSupport.await_down(ref, pid, close_grace_ms) do
      :down ->
        :ok

      :timeout ->
        safe_exit(pid, :shutdown)
        await_down_or_kill(ref, pid, shutdown_grace_ms, kill_grace_ms)
    end
  end

  defp await_down_or_kill(ref, pid, shutdown_grace_ms, kill_grace_ms) do
    case ProcessSupport.await_down(ref, pid, shutdown_grace_ms) do
      :down ->
        :ok

      :timeout ->
        safe_exit(pid, :kill)
        await_down_or_demonitor(ref, pid, kill_grace_ms)
    end
  end

  defp await_down_or_demonitor(ref, pid, kill_grace_ms) do
    case ProcessSupport.await_down(ref, pid, kill_grace_ms) do
      :down ->
        :ok

      :timeout ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp safe_close(close_fun, pid) do
    close_fun.(pid)
  catch
    :exit, _ -> :ok
  end

  defp safe_exit(pid, reason) do
    Process.exit(pid, reason)
    :ok
  catch
    :exit, _ -> :ok
  end
end
