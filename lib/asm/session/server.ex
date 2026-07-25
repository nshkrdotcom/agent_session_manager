defmodule ASM.Session.Server do
  @moduledoc """
  Session aggregate root for run admission, approval routing, and cost totals.
  """

  use GenServer

  alias ASM.{Control, Error, Metadata, RuntimeAuth}
  alias ASM.Provider
  alias ASM.Run.ApprovalCoordinator
  alias ASM.RuntimeAuth.ManagedBinding
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

  @spec revoke_materialization(GenServer.server(), map() | keyword()) ::
          :ok | {:error, Error.t()}
  def revoke_materialization(server, revocation) do
    GenServer.call(server, {:revoke_materialization, revocation})
  end

  @spec cleanup_materialization(GenServer.server(), atom()) :: :ok | {:error, Error.t()}
  def cleanup_materialization(server, reason \\ :scope_closed) when is_atom(reason) do
    GenServer.call(server, {:cleanup_materialization, reason})
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    provider = opts |> Keyword.get(:provider, :claude) |> Provider.resolve!()
    session_options = Keyword.get(opts, :options, [])
    runtime_auth = Keyword.fetch!(opts, :runtime_auth)

    state =
      session_id
      |> State.new(provider, session_options, runtime_auth)
      |> schedule_materialization_expiry()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:checkpoint, _from, state) do
    {:reply, {:ok, state.checkpoint}, state}
  end

  def handle_call({:revoke_materialization, revocation}, _from, state) do
    case RuntimeAuth.authorize_managed_revocation(state.runtime_auth, revocation) do
      :ok -> {:reply, :ok, terminate_materialization(state, :revoked)}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cleanup_materialization, _reason}, _from, state) do
    if is_nil(state.runtime_auth.managed_binding) do
      {:reply,
       {:error,
        Error.new(
          :config_invalid,
          :config,
          "cannot clean up materialization for an unmanaged ASM session"
        )}, state}
    else
      {:reply, :ok, terminate_materialization(state, :cleaned)}
    end
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

  def handle_info(:managed_materialization_expiry, state) do
    state = %{state | materialization_timer_ref: nil}

    case state.runtime_auth.managed_binding do
      nil ->
        {:noreply, state}

      binding ->
        case ManagedBinding.active(binding) do
          :ok -> {:noreply, schedule_materialization_expiry(state)}
          {:error, %Error{}} -> {:noreply, terminate_materialization(state, :expired)}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    cancel_materialization_timer(state.materialization_timer_ref)
    :ok
  end

  defp maybe_start_or_queue_run(state, run_id, prompt, run_opts) do
    max_active = state.provider_profile.max_concurrent_runs

    cond do
      state.status != :ready ->
        {:error, materialization_closed_error(state)}

      not managed_materialization_active?(state) ->
        send(self(), :managed_materialization_expiry)
        {:error, materialization_closed_error(state)}

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
    with {:ok, run_opts} <-
           RuntimeAuth.prepare_run_options(state.runtime_auth, state.options, run_opts) do
      run_module = Keyword.get(run_opts, :run_module, ASM.Run.Server)
      run_module_opts = Keyword.get(run_opts, :run_module_opts, [])
      passthrough_opts = Keyword.drop(run_opts, [:run_module, :run_module_opts])

      {runtime_auth_opts, passthrough_opts} =
        Keyword.split(passthrough_opts, RuntimeAuth.option_keys())

      do_start_run_child(
        state,
        run_sup,
        run_id,
        prompt,
        runtime_auth_opts,
        passthrough_opts,
        run_module,
        run_module_opts
      )
    end
  end

  defp do_start_run_child(
         state,
         run_sup,
         run_id,
         prompt,
         runtime_auth_opts,
         passthrough_opts,
         run_module,
         run_module_opts
       ) do
    with {:ok, runtime_auth} <- RuntimeAuth.for_run(state.runtime_auth, run_id, runtime_auth_opts) do
      passthrough_opts =
        put_runtime_auth_metadata(passthrough_opts, RuntimeAuth.to_metadata(runtime_auth))

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
  end

  defp put_runtime_auth_metadata(opts, metadata) when is_list(opts) and is_map(metadata) do
    existing_metadata =
      case Keyword.get(opts, :metadata, %{}) do
        existing when is_map(existing) -> existing
        _other -> %{}
      end

    opts
    |> Keyword.delete(:metadata)
    |> Keyword.put(:metadata, Metadata.merge_run_metadata(metadata, existing_metadata))
  end

  defp maybe_start_next_queued_run(%State{status: status} = state) when status != :ready,
    do: state

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

  defp schedule_materialization_expiry(
         %State{status: :ready, runtime_auth: %{managed_binding: %ManagedBinding{} = binding}} =
           state
       ) do
    cancel_materialization_timer(state.materialization_timer_ref)

    timeout = min(ManagedBinding.remaining_ms(binding), 4_294_967_295)
    timer_ref = Process.send_after(self(), :managed_materialization_expiry, timeout)
    %{state | materialization_timer_ref: timer_ref}
  end

  defp schedule_materialization_expiry(%State{} = state), do: state

  defp terminate_materialization(%State{} = state, materialization_status)
       when materialization_status in [:expired, :revoked, :cleaned] do
    cancel_materialization_timer(state.materialization_timer_ref)
    terminate_active_runs(state)

    Enum.each(state.run_monitors, fn {_run_pid, monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    %{
      state
      | status: :stopped,
        materialization_status: materialization_status,
        materialization_timer_ref: nil,
        active_runs: %{},
        run_monitors: %{},
        run_queue: :queue.new(),
        pending_approval_index: %{},
        options:
          Keyword.drop(state.options, [
            :codex_materialized_runtime,
            :secret_material,
            :materialization_request
          ])
    }
  end

  defp terminate_active_runs(%State{} = state) do
    Enum.each(state.active_runs, fn {_run_id, run_pid} ->
      GenServer.cast(run_pid, :interrupt)
    end)

    case lookup_run_supervisor(state.session_id) do
      {:ok, run_supervisor} ->
        Enum.each(state.active_runs, fn {_run_id, run_pid} ->
          _ = DynamicSupervisor.terminate_child(run_supervisor, run_pid)
        end)

      {:error, %Error{}} ->
        :ok
    end
  end

  defp managed_materialization_active?(%State{runtime_auth: %{managed_binding: nil}}), do: true

  defp managed_materialization_active?(%State{runtime_auth: %{managed_binding: binding}}),
    do: ManagedBinding.active(binding) == :ok

  defp materialization_closed_error(%State{} = state) do
    Error.new(
      :config_invalid,
      :config,
      "managed session materialization is no longer active",
      provider: state.provider.name,
      cause: %{materialization_status: state.materialization_status}
    )
  end

  defp cancel_materialization_timer(nil), do: :ok

  defp cancel_materialization_timer(timer_ref) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
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
