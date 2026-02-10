defmodule AgentSessionManager.StreamSession.Lifecycle do
  @moduledoc false

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.SessionManager

  defstruct [
    :store_pid,
    :adapter_pid,
    :task_pid,
    :task_monitor,
    :stream_ref,
    :shutdown_timeout,
    owns_store: false,
    owns_adapter: false
  ]

  @doc "Start store + adapter, launch run_once task, return resources."
  def acquire(config) do
    with {:ok, store_pid, owns_store} <- resolve_store(config),
         {:ok, adapter_pid, owns_adapter} <- resolve_adapter(config, store_pid, owns_store) do
      {task_pid, task_monitor, stream_ref} = launch_task(store_pid, adapter_pid, config)

      {:ok,
       %__MODULE__{
         store_pid: store_pid,
         adapter_pid: adapter_pid,
         task_pid: task_pid,
         task_monitor: task_monitor,
         stream_ref: stream_ref,
         owns_store: owns_store,
         owns_adapter: owns_adapter,
         shutdown_timeout: config.shutdown_timeout
       }}
    end
  end

  @doc "Stop task + terminate owned children. Idempotent."
  def release(%__MODULE__{} = resources) do
    stop_task(resources.task_pid, resources.shutdown_timeout)

    if resources.owns_adapter, do: stop_child(resources.adapter_pid)
    if resources.owns_store, do: stop_child(resources.store_pid)

    if resources.task_monitor do
      Process.demonitor(resources.task_monitor, [:flush])
    end

    :ok
  end

  # -- Store resolution

  defp resolve_store(%{store: pid}) when is_pid(pid), do: {:ok, pid, false}

  defp resolve_store(%{store: name}) when is_atom(name) and not is_nil(name),
    do: {:ok, name, false}

  defp resolve_store(_config) do
    case InMemorySessionStore.start_link([]) do
      {:ok, pid} -> {:ok, pid, true}
      {:error, reason} -> {:error, {:store_start_failed, reason}}
    end
  end

  # -- Adapter resolution

  defp resolve_adapter(%{adapter: pid}, _store_pid, _owns_store) when is_pid(pid) do
    {:ok, pid, false}
  end

  defp resolve_adapter(%{adapter: name}, _store_pid, _owns_store)
       when is_atom(name) and not is_nil(name) do
    {:ok, name, false}
  end

  defp resolve_adapter(%{adapter: {module, opts}}, store_pid, owns_store) do
    case module.start_link(opts) do
      {:ok, pid} ->
        {:ok, pid, true}

      {:error, reason} ->
        if owns_store, do: stop_child(store_pid)
        {:error, {:adapter_start_failed, reason}}
    end
  end

  defp resolve_adapter(_config, store_pid, owns_store) do
    if owns_store, do: stop_child(store_pid)
    {:error, {:invalid_adapter, "adapter must be {Module, opts}, pid, or registered name"}}
  end

  # -- Task launch

  defp launch_task(store_pid, adapter_pid, config) do
    stream_ref = make_ref()
    parent = self()

    task_fun = fn ->
      run_session(store_pid, adapter_pid, config, parent, stream_ref)
    end

    # Task.start_link/1 always returns {:ok, pid} (raises on failure)
    {:ok, task_pid} = Task.start_link(task_fun)
    task_monitor = Process.monitor(task_pid)
    {task_pid, task_monitor, stream_ref}
  end

  defp run_session(store_pid, adapter_pid, config, parent, stream_ref) do
    event_callback = fn event -> send(parent, {stream_ref, :event, event}) end

    run_opts =
      config.run_opts
      |> Keyword.put(:event_callback, event_callback)
      |> maybe_put(:agent_id, config.agent_id)

    result = SessionManager.run_once(store_pid, adapter_pid, config.input, run_opts)
    send(parent, {stream_ref, :done, result})
  rescue
    exception ->
      send(parent, {stream_ref, :done, {:error, {:exception, exception, __STACKTRACE__}}})
  catch
    kind, reason ->
      send(parent, {stream_ref, :done, {:error, {kind, reason}}})
  end

  # -- Cleanup

  defp stop_task(nil, _timeout), do: :ok

  defp stop_task(task_pid, timeout) when is_pid(task_pid) do
    if Process.alive?(task_pid) do
      Process.unlink(task_pid)
      Process.exit(task_pid, :shutdown)
      await_task_exit(task_pid, timeout)
    end

    :ok
  end

  defp await_task_exit(task_pid, timeout) do
    ref = Process.monitor(task_pid)

    receive do
      {:DOWN, ^ref, :process, ^task_pid, _reason} -> :ok
    after
      timeout ->
        Process.exit(task_pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^task_pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end

    Process.demonitor(ref, [:flush])
  end

  defp stop_child(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp stop_child(_), do: :ok

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
