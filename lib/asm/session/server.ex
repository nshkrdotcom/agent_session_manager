defmodule ASM.Session.Server do
  @moduledoc """
  Session aggregate root for run admission, approval routing, and cost totals.
  """

  use GenServer

  alias ASM.{Control, Error}
  alias ASM.Provider
  alias ASM.Run.ApprovalCoordinator
  alias ASM.Session.Continuation
  alias ASM.Session.State
  alias ASM.SessionControl
  alias CliSubprocessCore.Payload

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server), do: GenServer.call(server, :get_state)

  @spec submit_run(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def submit_run(server, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    GenServer.call(server, {:submit_run, prompt, opts})
  end

  @spec cancel_run(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def cancel_run(server, run_id) when is_binary(run_id) do
    GenServer.call(server, {:cancel_run, run_id})
  end

  @spec resolve_approval(GenServer.server(), String.t(), :allow | :deny) ::
          :ok | {:error, Error.t()}
  def resolve_approval(server, approval_id, decision)
      when is_binary(approval_id) and decision in [:allow, :deny] do
    GenServer.call(server, {:resolve_approval, approval_id, decision})
  end

  @spec pause_run(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def pause_run(server, run_id) when is_binary(run_id) do
    GenServer.call(server, {:pause_run, run_id})
  end

  @spec checkpoint(GenServer.server()) :: {:ok, map() | nil} | {:error, Error.t()}
  def checkpoint(server) do
    GenServer.call(server, :checkpoint)
  end

  @spec resume_run(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def resume_run(server, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    GenServer.call(server, {:resume_run, prompt, opts})
  end

  @spec intervene(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def intervene(server, run_id, prompt, opts \\ [])
      when is_binary(run_id) and is_binary(prompt) and is_list(opts) do
    GenServer.call(server, {:intervene, run_id, prompt, opts})
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    provider = opts |> Keyword.get(:provider, :claude) |> Provider.resolve!()
    session_options = Keyword.get(opts, :options, [])

    {:ok, State.new(session_id, provider, session_options)}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:checkpoint, _from, state) do
    {:reply, {:ok, state.checkpoint}, state}
  end

  @impl true
  def handle_call({:submit_run, prompt, opts}, _from, state) do
    run_id = Keyword.get_lazy(opts, :run_id, &ASM.Event.generate_id/0)
    run_opts = Keyword.drop(opts, [:run_id])

    case maybe_start_or_queue_run(state, run_id, prompt, run_opts) do
      {:ok, pid, next_state} ->
        {:reply, {:ok, run_id, pid}, next_state}

      {:queued, next_state} ->
        {:reply, {:ok, run_id, :queued}, next_state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    case Map.fetch(state.active_runs, run_id) do
      {:ok, run_pid} ->
        GenServer.cast(run_pid, :interrupt)
        {:reply, :ok, state}

      :error ->
        {removed?, new_queue} = remove_queued_run(state.run_queue, run_id)

        if removed? do
          {:reply, :ok, %{state | run_queue: new_queue}}
        else
          {:reply, {:error, runtime_error(:unknown, "Unknown run id: #{run_id}")}, state}
        end
    end
  end

  def handle_call({:pause_run, run_id}, _from, state) do
    case Map.fetch(state.active_runs, run_id) do
      {:ok, run_pid} ->
        GenServer.cast(run_pid, :interrupt)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, runtime_error(:unknown, "Unknown active run id: #{run_id}")}, state}
    end
  end

  def handle_call({:resume_run, prompt, opts}, _from, state) do
    case build_continuation(state, opts) do
      {:ok, continuation} ->
        run_id = Keyword.get_lazy(opts, :run_id, &ASM.Event.generate_id/0)

        run_opts =
          opts
          |> Keyword.drop([:run_id, :target, :continuation])
          |> Keyword.put(:continuation, continuation)

        case maybe_start_or_queue_run(state, run_id, prompt, run_opts) do
          {:ok, pid, next_state} ->
            {:reply, {:ok, run_id, pid}, next_state}

          {:queued, next_state} ->
            {:reply, {:ok, run_id, :queued}, next_state}

          {:error, %Error{} = error} ->
            {:reply, {:error, error}, state}
        end

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:intervene, run_id, prompt, opts}, _from, state) do
    with :ok <- pause_active_run(state, run_id),
         {:ok, continuation} <- build_continuation(state, opts) do
      resumed_run_id = Keyword.get_lazy(opts, :run_id, &ASM.Event.generate_id/0)

      run_opts =
        opts
        |> Keyword.drop([:run_id, :target, :continuation])
        |> Keyword.put(:continuation, continuation)
        |> Keyword.put_new(:intervention_for_run_id, run_id)

      case maybe_start_or_queue_run(state, resumed_run_id, prompt, run_opts) do
        {:ok, pid, next_state} ->
          {:reply, {:ok, resumed_run_id, pid}, next_state}

        {:queued, next_state} ->
          {:reply, {:ok, resumed_run_id, :queued}, next_state}

        {:error, %Error{} = error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:resolve_approval, approval_id, decision}, _from, state) do
    case ApprovalCoordinator.resolve(state.pending_approval_index, approval_id) do
      {:error, :unknown_approval, _remaining} ->
        {:reply, {:error, Error.new(:unknown, :approval, "Unknown approval id: #{approval_id}")},
         state}

      {:ok, run_pid, remaining} ->
        GenServer.cast(run_pid, {:resolve_approval, approval_id, decision})
        {:reply, :ok, %{state | pending_approval_index: remaining}}
    end
  end

  @impl true
  def handle_info({:register_approval, run_pid, %Control.ApprovalRequest{} = request}, state)
      when is_pid(run_pid) do
    index = ApprovalCoordinator.register(state.pending_approval_index, run_pid, request)
    {:noreply, %{state | pending_approval_index: index}}
  end

  def handle_info({:clear_approval, approval_id}, state) when is_binary(approval_id) do
    {:noreply,
     %{
       state
       | pending_approval_index:
           ApprovalCoordinator.clear(state.pending_approval_index, approval_id)
     }}
  end

  def handle_info({:cost_update, %Control.CostUpdate{} = payload}, state) do
    {:noreply, %{state | cost: add_cost(state.cost, payload)}}
  end

  def handle_info({:capture_checkpoint, run_id, provider_session_id, metadata}, state)
      when is_binary(run_id) and is_binary(provider_session_id) and provider_session_id != "" do
    checkpoint =
      Continuation.capture(state, %{
        run_id: run_id,
        provider_session_id: provider_session_id,
        metadata: normalize_checkpoint_metadata(metadata)
      })

    {:noreply, Continuation.restore(state, checkpoint)}
  end

  def handle_info({:DOWN, ref, :process, run_pid, _reason}, state) do
    case Map.fetch(state.run_monitors, run_pid) do
      {:ok, ^ref} ->
        state
        |> clear_run_by_pid(run_pid)
        |> maybe_start_next_queued_run()
        |> then(&{:noreply, &1})

      _ ->
        {:noreply, state}
    end
  end

  defp maybe_start_or_queue_run(state, run_id, prompt, run_opts) do
    max_active = state.provider_profile.max_concurrent_runs

    cond do
      map_size(state.active_runs) < max_active ->
        start_run(state, run_id, prompt, run_opts)

      queue_has_capacity?(state) ->
        queue_entry = %{run_id: run_id, prompt: prompt, opts: run_opts}
        {:queued, %{state | run_queue: :queue.in(queue_entry, state.run_queue)}}

      true ->
        {:error, runtime_error(:at_capacity, "Session at run capacity")}
    end
  end

  defp queue_has_capacity?(state) do
    max_queued = state.provider_profile.max_queued_runs
    max_queued > 0 and :queue.len(state.run_queue) < max_queued
  end

  defp start_run(state, run_id, prompt, run_opts) do
    with {:ok, run_sup} <- lookup_run_supervisor(state.session_id),
         {:ok, run_pid} <- start_run_child(state, run_sup, run_id, prompt, run_opts) do
      monitor_ref = Process.monitor(run_pid)

      next_state = %{
        state
        | active_runs: Map.put(state.active_runs, run_id, run_pid),
          run_monitors: Map.put(state.run_monitors, run_pid, monitor_ref)
      }

      {:ok, run_pid, next_state}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, runtime_error(:runtime, "Failed to start run: #{inspect(reason)}")}
    end
  end

  defp lookup_run_supervisor(session_id) do
    case Registry.lookup(:asm_sessions, {session_id, :run_sup}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        {:error, runtime_error(:runtime, "Run supervisor not found for session #{session_id}")}
    end
  end

  defp start_run_child(state, run_sup, run_id, prompt, run_opts) do
    run_module = Keyword.get(run_opts, :run_module, ASM.Run.Server)
    run_module_opts = Keyword.get(run_opts, :run_module_opts, [])
    passthrough_opts = Keyword.drop(run_opts, [:run_module, :run_module_opts])

    child_opts =
      [
        run_id: run_id,
        session_id: state.session_id,
        provider: state.provider.name,
        prompt: prompt,
        session_pid: self()
      ] ++ passthrough_opts ++ run_module_opts

    DynamicSupervisor.start_child(run_sup, {run_module, child_opts})
  end

  defp maybe_start_next_queued_run(state) do
    case :queue.out(state.run_queue) do
      {{:value, %{run_id: run_id, prompt: prompt, opts: opts}}, remaining}
      when map_size(state.active_runs) < state.provider_profile.max_concurrent_runs ->
        case start_run(%{state | run_queue: remaining}, run_id, prompt, opts) do
          {:ok, _pid, started_state} ->
            started_state

          {:error, %Error{} = error} ->
            notify_queued_run_start_failure(state, run_id, opts, error)
            maybe_start_next_queued_run(%{state | run_queue: remaining})
        end

      _ ->
        state
    end
  end

  defp clear_run_by_pid(state, run_pid) do
    {run_id, active_runs} = pop_run_by_pid(state.active_runs, run_pid)
    monitor_ref = Map.get(state.run_monitors, run_pid)

    if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])

    pending_approval_index = drop_approvals_for_pid(state.pending_approval_index, run_pid)

    if run_id do
      %{
        state
        | active_runs: active_runs,
          run_monitors: Map.delete(state.run_monitors, run_pid),
          pending_approval_index: pending_approval_index
      }
    else
      %{
        state
        | run_monitors: Map.delete(state.run_monitors, run_pid),
          pending_approval_index: pending_approval_index
      }
    end
  end

  defp pop_run_by_pid(active_runs, run_pid) do
    case Enum.find(active_runs, fn {_run_id, pid} -> pid == run_pid end) do
      {run_id, _pid} -> {run_id, Map.delete(active_runs, run_id)}
      nil -> {nil, active_runs}
    end
  end

  defp drop_approvals_for_pid(index, run_pid) do
    index
    |> Enum.reject(fn {_approval_id, pid} -> pid == run_pid end)
    |> Map.new()
  end

  defp remove_queued_run(queue, run_id) do
    list = :queue.to_list(queue)

    if Enum.any?(list, fn entry -> entry.run_id == run_id end) do
      trimmed = Enum.reject(list, fn entry -> entry.run_id == run_id end)
      {true, :queue.from_list(trimmed)}
    else
      {false, queue}
    end
  end

  defp build_continuation(%State{} = state, opts) when is_list(opts) do
    case Keyword.get(opts, :continuation) do
      nil ->
        SessionControl.continuation_from_checkpoint(
          state.checkpoint,
          Keyword.take(opts, [:target])
        )

      continuation when is_map(continuation) ->
        {:ok, continuation}

      other ->
        {:error,
         runtime_error(
           :config_invalid,
           "invalid continuation #{inspect(other)}; expected a continuation map or nil"
         )}
    end
  end

  defp pause_active_run(%State{active_runs: active_runs}, run_id) when is_binary(run_id) do
    case Map.fetch(active_runs, run_id) do
      {:ok, run_pid} ->
        GenServer.cast(run_pid, :interrupt)
        :ok

      :error ->
        {:error, runtime_error(:unknown, "Unknown active run id: #{run_id}")}
    end
  end

  defp normalize_checkpoint_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_checkpoint_metadata(_metadata), do: %{}

  defp runtime_error(kind, message) do
    Error.new(kind, :runtime, message)
  end

  defp add_cost(current, %Control.CostUpdate{} = payload) do
    %{
      input_tokens: default_zero(current[:input_tokens]) + payload.input_tokens,
      output_tokens: default_zero(current[:output_tokens]) + payload.output_tokens,
      cost_usd: default_zero(current[:cost_usd]) + payload.cost_usd
    }
  end

  defp default_zero(nil), do: 0
  defp default_zero(value), do: value

  defp notify_queued_run_start_failure(%State{} = state, run_id, opts, %Error{} = error)
       when is_binary(run_id) and is_list(opts) do
    case queued_run_subscriber(opts) do
      pid when is_pid(pid) ->
        event =
          ASM.Event.new(
            :error,
            Payload.Error.new(
              message: error.message,
              code: to_string(error.kind),
              metadata: %{asm_error_domain: error.domain}
            ),
            run_id: run_id,
            session_id: state.session_id,
            provider: state.provider.name,
            timestamp: DateTime.utc_now()
          )

        send(pid, {:asm_run_event, run_id, event})
        send(pid, {:asm_run_done, run_id})
        :ok

      _ ->
        :ok
    end
  end

  defp queued_run_subscriber(opts) when is_list(opts) do
    opts
    |> Keyword.get(:run_module_opts, [])
    |> case do
      module_opts when is_list(module_opts) -> Keyword.get(module_opts, :subscriber)
      _other -> nil
    end
  end
end
