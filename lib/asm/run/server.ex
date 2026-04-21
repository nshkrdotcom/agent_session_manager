defmodule ASM.Run.Server do
  @moduledoc """
  Per-run worker that owns backend lifecycle and event fanout.
  """

  use GenServer, restart: :temporary

  alias ASM.{Error, Event, Metadata, Provider, ProviderRegistry, ProviderRuntimeProfile, Run}
  alias ASM.Execution.{Config, PolicyPlug}
  alias ASM.ProviderBackend.Event, as: BackendEvent
  alias ASM.ProviderBackend.Info, as: BackendInfo
  alias CliSubprocessCore.Payload

  @boot_timeout_ms 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    caller = self()
    reply_ref = make_ref()

    with_trap_exit(fn ->
      case GenServer.start_link(__MODULE__, {caller, reply_ref, opts}) do
        {:ok, pid} ->
          await_bootstrap(pid, reply_ref, Keyword.get(opts, :boot_timeout_ms, @boot_timeout_ms))

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec interrupt(GenServer.server()) :: :ok
  def interrupt(server) do
    GenServer.cast(server, :interrupt)
    :ok
  end

  @spec ingest_event(GenServer.server(), Event.t()) :: :ok
  def ingest_event(server, %Event{} = event) do
    GenServer.cast(server, {:ingest_event, event})
    :ok
  end

  @spec get_state(GenServer.server()) :: Run.State.t()
  def get_state(server), do: GenServer.call(server, :get_state)

  @spec resolve_approval(GenServer.server(), String.t(), :allow | :deny) :: :ok
  def resolve_approval(server, approval_id, decision) do
    GenServer.cast(server, {:resolve_approval, approval_id, decision})
    :ok
  end

  @impl true
  def init({caller, reply_ref, opts}) when is_list(opts) do
    Process.put({__MODULE__, :boot_waiter}, {caller, reply_ref})
    {:ok, Run.State.new(opts), {:continue, :bootstrap}}
  end

  def init(opts) when is_list(opts) do
    {:ok, Run.State.new(opts), {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case start_backend(state) do
      {:ok, next_state} ->
        _ = ASM.Telemetry.run_started(state.session_id, state.run_id, state.provider)
        notify_bootstrap_waiter(:ok)
        {:noreply, next_state}

      {:error, %Error{} = error, next_state} ->
        notify_bootstrap_waiter({:error, error})
        _ = maybe_close_backend(next_state)
        {:stop, :normal, %{next_state | error: error}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Run.State.materialize(state), state}
  end

  @impl true
  def handle_cast({:ingest_event, %Event{} = event}, state) do
    consume_event(state, event)
  end

  def handle_cast(:interrupt, state) do
    _ = maybe_interrupt_backend(state)

    event =
      Event.new(
        :error,
        Payload.Error.new(message: "Run interrupted", code: "user_cancelled", severity: :warning),
        run_id: state.run_id,
        session_id: state.session_id,
        provider: state.provider,
        timestamp: DateTime.utc_now()
      )

    next_state =
      state
      |> process_events([event])
      |> Map.put(:status, :interrupted)
      |> Map.put(:finished_at, DateTime.utc_now())
      |> Map.put(:error, Error.new(:user_cancelled, :runtime, "Run interrupted"))

    finish_run(next_state)
  end

  def handle_cast({:resolve_approval, approval_id, decision}, state) do
    if Map.has_key?(state.pending_approvals, approval_id) do
      state = clear_approval_timer(state, approval_id)
      notify_session(state, {:clear_approval, approval_id})

      event =
        Event.new(
          :approval_resolved,
          Payload.ApprovalResolved.new(approval_id: approval_id, decision: decision),
          run_id: state.run_id,
          session_id: state.session_id,
          provider: state.provider,
          timestamp: DateTime.utc_now()
        )

      next_state = process_events(state, [event])
      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        %BackendEvent{subscription_ref: ref, core_event: core_event},
        %{backend_subscription_ref: ref} = state
      ) do
    event =
      Event.wrap_core(
        %{run_id: state.run_id, session_id: state.session_id, provider: state.provider},
        core_event
      )

    consume_event(state, event)
  end

  def handle_info({:approval_timeout, approval_id}, state) do
    if Map.has_key?(state.pending_approvals, approval_id) do
      state = clear_approval_timer(state, approval_id)
      notify_session(state, {:clear_approval, approval_id})

      event =
        Event.new(
          :approval_resolved,
          Payload.ApprovalResolved.new(
            approval_id: approval_id,
            decision: :deny,
            reason: "timeout"
          ),
          run_id: state.run_id,
          session_id: state.session_id,
          provider: state.provider,
          timestamp: DateTime.utc_now()
        )

      {:noreply, process_events(state, [event])}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{backend_ref: ref} = state) do
    next_state = %{state | backend_pid: nil, backend_ref: nil}

    cond do
      Run.EventReducer.final?(next_state) ->
        {:noreply, next_state}

      reason in [:normal, :shutdown] ->
        event =
          Event.new(
            :run_completed,
            %{status: :completed},
            run_id: next_state.run_id,
            session_id: next_state.session_id,
            provider: next_state.provider,
            timestamp: DateTime.utc_now()
          )

        finish_run(process_events(next_state, [event]))

      true ->
        event =
          Event.new(
            :error,
            Payload.Error.new(
              message: "backend crashed: #{inspect(reason)}",
              code: "transport_error"
            ),
            run_id: next_state.run_id,
            session_id: next_state.session_id,
            provider: next_state.provider,
            timestamp: DateTime.utc_now()
          )

        finish_run(process_events(next_state, [event]))
    end
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_approval_timers(state)
    _ = maybe_close_backend(state)
    :ok
  end

  defp start_backend(%Run.State{} = state) do
    with {:ok, provider} <- Provider.resolve(state.provider),
         {:ok, resolution} <-
           resolve_backend(provider, state),
         start_config <- backend_start_config(provider, state, resolution),
         {:ok, pid, info} <- resolution.backend.start_run(start_config) do
      detach_backend_link(pid)
      bootstrap_backend_session(state, resolution, pid, info, start_config)
    else
      {:error, %Error{} = error} ->
        {:error, error, state}

      {:error, reason} ->
        {:error,
         Error.new(:runtime, :runtime, "backend start failed: #{inspect(reason)}", cause: reason),
         state}
    end
  end

  defp bootstrap_backend_session(state, resolution, pid, info, start_config) do
    with :ok <- maybe_subscribe_backend(resolution.backend, pid, start_config.subscription_ref),
         next_state <- put_backend_state(state, resolution, pid, info, start_config),
         :ok <- deliver_prompt(next_state) do
      {:ok, next_state}
    else
      {:error, %Error{} = error} ->
        _ = safe_close_backend(resolution.backend, pid)
        {:error, error, state}
    end
  end

  defp maybe_subscribe_backend(ASM.ProviderBackend.Core, _pid, _ref), do: :ok

  defp maybe_subscribe_backend(backend, pid, ref), do: subscribe_backend(backend, pid, ref)

  defp resolve_backend(provider, %Run.State{backend: backend} = state)
       when is_atom(backend) and not is_nil(backend) do
    with {:ok, runtime_profile} <- ProviderRuntimeProfile.resolve(provider.name),
         :ok <- validate_backend_override(provider, backend, runtime_profile) do
      lane = backend_override_lane(state.lane)
      capabilities = backend_override_capabilities(provider, lane)
      execution_mode = execution_mode(state)

      {:ok,
       %{
         provider: provider,
         backend: backend,
         requested_lane: state.lane || lane,
         preferred_lane: lane,
         lane: lane,
         capabilities: capabilities,
         provider_runtime_profile: runtime_profile,
         observability:
           %{
             provider: provider.name,
             provider_display_name: provider.display_name,
             requested_lane: state.lane || lane,
             preferred_lane: lane,
             lane: lane,
             lane_reason: :backend_override,
             lane_fallback_reason: nil,
             execution_mode: execution_mode,
             backend: backend,
             capabilities: capabilities
           }
           |> Map.merge(ProviderRuntimeProfile.observability(runtime_profile))
       }}
    end
  end

  defp resolve_backend(provider, %Run.State{} = state) do
    ProviderRegistry.resolve(provider.name,
      lane: state.lane || :auto,
      execution_mode: execution_mode(state)
    )
  end

  defp backend_start_config(provider, state, resolution) do
    subscription_ref = make_ref()

    %{
      provider: provider,
      lane: resolution.lane,
      backend: resolution.backend,
      prompt: state.prompt,
      continuation: state.continuation,
      provider_opts: state.provider_opts,
      backend_opts: state.backend_opts,
      execution_config: state.execution_config,
      subscriber_pid: self(),
      subscription_ref: subscription_ref,
      metadata: %{run_id: state.run_id, session_id: state.session_id}
    }
  end

  defp detach_backend_link(pid) when is_pid(pid) do
    Process.unlink(pid)
    :ok
  rescue
    _ -> :ok
  end

  defp subscribe_backend(backend, pid, ref) when is_atom(backend) and is_pid(pid) do
    case backend.subscribe(pid, self(), ref) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        _ = safe_close_backend(backend, pid)
        {:error, error}

      {:error, reason} ->
        _ = safe_close_backend(backend, pid)

        {:error,
         Error.new(
           :runtime,
           :runtime,
           "backend subscribe failed: #{inspect(reason)}",
           cause: reason
         )}
    end
  rescue
    error ->
      _ = safe_close_backend(backend, pid)
      {:error, Error.new(:runtime, :runtime, Exception.message(error), cause: error)}
  end

  defp put_backend_state(state, resolution, pid, info, start_config) do
    ref = Process.monitor(pid)

    backend_info = resolved_backend_info(info, resolution, pid)

    %{
      state
      | backend: resolution.backend,
        backend_pid: pid,
        backend_ref: ref,
        backend_subscription_ref: start_config.subscription_ref,
        backend_info: backend_info,
        lane: resolution.lane,
        metadata: Map.merge(state.metadata, backend_info.observability)
    }
  end

  defp deliver_prompt(%Run.State{backend: ASM.ProviderBackend.SDK, provider: :claude} = state) do
    case state.backend.send_input(state.backend_pid, state.prompt, []) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:runtime, :runtime, "prompt delivery failed: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  defp deliver_prompt(_state), do: :ok

  defp consume_event(state, %Event{} = event) do
    case apply_pipeline(state, event) do
      {:ok, events, next_state} ->
        next_state = process_events(next_state, events)

        if Run.EventReducer.final?(next_state) do
          finish_run(next_state)
        else
          {:noreply, next_state}
        end

      {:error, %Error{} = error, next_state} ->
        error_event =
          Event.new(
            :error,
            error_payload(error),
            run_id: next_state.run_id,
            session_id: next_state.session_id,
            provider: next_state.provider,
            timestamp: DateTime.utc_now()
          )

        finish_run(process_events(next_state, [error_event]))
    end
  end

  defp apply_pipeline(state, event) do
    case ASM.Pipeline.run(
           event,
           execution_policy_pipeline(state) ++ state.pipeline,
           state.pipeline_ctx
         ) do
      {:ok, events, pipeline_ctx} ->
        {:ok, events, %{state | pipeline_ctx: pipeline_ctx}}

      {:error, %Error{} = error, pipeline_ctx} ->
        {:error, error, %{state | pipeline_ctx: pipeline_ctx}}
    end
  rescue
    error ->
      {:error, Error.new(:runtime, :runtime, Exception.message(error), cause: error), state}
  end

  defp execution_policy_pipeline(%Run.State{execution_config: %Config{} = config}) do
    case Config.to_execution_environment(config).allowed_tools do
      [] -> []
      allowed_tools -> [{PolicyPlug, allowed_tools: allowed_tools}]
    end
  end

  defp execution_policy_pipeline(_state), do: []

  defp process_events(state, events) when is_list(events) do
    Enum.reduce(events, state, fn event, acc ->
      event = merge_event_metadata(event, acc.metadata)
      next_state = Run.EventReducer.apply_event!(acc, event)
      maybe_capture_checkpoint(next_state, event)
      fanout(next_state, event)
      maybe_track_approval(next_state, event)
    end)
  end

  defp maybe_track_approval(state, %Event{kind: :approval_requested} = event) do
    payload = Event.legacy_payload(event)
    notify_session(state, {:register_approval, self(), payload})

    timer_ref =
      Process.send_after(
        self(),
        {:approval_timeout, payload.approval_id},
        state.approval_timeout_ms
      )

    put_in(state.approval_timers[payload.approval_id], timer_ref)
  end

  defp maybe_track_approval(state, _event), do: state

  defp fanout(%Run.State{} = state, %Event{kind: :cost_update} = event) do
    notify_session(state, {:cost_update, Event.legacy_payload(event)})
    fanout_to_subscriber(state, event)
  end

  defp fanout(%Run.State{} = state, event) do
    fanout_to_subscriber(state, event)
  end

  defp fanout_to_subscriber(%Run.State{subscriber: subscriber}, event) when is_pid(subscriber) do
    send(subscriber, {:asm_run_event, event.run_id, event})
  end

  defp fanout_to_subscriber(_state, _event), do: :ok

  defp finish_run(state) do
    notify_done(state)
    _ = maybe_close_backend(state)
    _ = ASM.Telemetry.run_completed(state.session_id, state.run_id, state.provider, state.status)
    {:stop, :normal, state}
  end

  defp notify_done(%Run.State{subscriber: subscriber, run_id: run_id}) when is_pid(subscriber) do
    send(subscriber, {:asm_run_done, run_id})
  end

  defp notify_done(_state), do: :ok

  defp notify_session(%Run.State{session_pid: session_pid}, message) when is_pid(session_pid) do
    send(session_pid, message)
  end

  defp notify_session(_state, _message), do: :ok

  defp maybe_capture_checkpoint(
         %Run.State{} = state,
         %Event{provider_session_id: provider_session_id} = event
       )
       when is_binary(provider_session_id) and provider_session_id != "" do
    notify_session(
      state,
      {:capture_checkpoint, event.run_id, provider_session_id,
       normalize_checkpoint_metadata(event.metadata)}
    )
  end

  defp maybe_capture_checkpoint(_state, _event), do: :ok

  defp clear_approval_timer(state, approval_id) do
    case Map.pop(state.approval_timers, approval_id) do
      {nil, timers} ->
        %{state | approval_timers: timers}

      {timer_ref, timers} ->
        _ = Process.cancel_timer(timer_ref, async: true, info: false)
        %{state | approval_timers: timers}
    end
  end

  defp cleanup_approval_timers(state) do
    Enum.each(state.approval_timers, fn {_approval_id, timer_ref} ->
      _ = Process.cancel_timer(timer_ref, async: true, info: false)
    end)
  end

  defp maybe_interrupt_backend(%Run.State{backend: backend, backend_pid: pid})
       when is_atom(backend) and is_pid(pid) do
    backend.interrupt(pid)
  rescue
    _ -> :ok
  end

  defp maybe_interrupt_backend(_state), do: :ok

  defp maybe_close_backend(%Run.State{backend: backend, backend_pid: pid})
       when is_atom(backend) and is_pid(pid) do
    safe_close_backend(backend, pid)
  rescue
    _ -> :ok
  end

  defp maybe_close_backend(_state), do: :ok

  defp safe_close_backend(backend, pid) when is_atom(backend) and is_pid(pid) do
    backend.close(pid)
  rescue
    _ -> :ok
  end

  defp await_bootstrap(pid, reply_ref, timeout_ms) when is_pid(pid) and is_reference(reply_ref) do
    receive do
      {:asm_run_bootstrapped, ^reply_ref} ->
        {:ok, pid}

      {:asm_run_boot_failed, ^reply_ref, %Error{} = error} ->
        safe_stop_run(pid)
        {:error, error}

      {:EXIT, ^pid, %Error{} = error} ->
        {:error, error}

      {:EXIT, ^pid, reason} ->
        {:error, normalize_bootstrap_exit(reason)}
    after
      timeout_ms ->
        safe_stop_run(pid)
        {:error, Error.new(:timeout, :runtime, "run bootstrap timed out")}
    end
  end

  defp safe_stop_run(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp normalize_bootstrap_exit(%Error{} = error), do: error

  defp normalize_bootstrap_exit({%Error{} = error, _stacktrace}), do: error

  defp normalize_bootstrap_exit(reason) do
    Error.new(:runtime, :runtime, "run bootstrap failed: #{inspect(reason)}", cause: reason)
  end

  defp notify_bootstrap_waiter(message) do
    case Process.delete({__MODULE__, :boot_waiter}) do
      {caller, reply_ref} when is_pid(caller) and is_reference(reply_ref) ->
        payload =
          case message do
            :ok -> {:asm_run_bootstrapped, reply_ref}
            {:error, %Error{} = error} -> {:asm_run_boot_failed, reply_ref, error}
          end

        send(caller, payload)
        :ok

      _ ->
        :ok
    end
  end

  defp with_trap_exit(fun) when is_function(fun, 0) do
    previous_trap_exit? = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, previous_trap_exit?)
    end
  end

  defp error_payload(%Error{} = error) do
    Payload.Error.new(
      message: error.message,
      code: to_string(error.kind),
      metadata: %{asm_error_domain: error.domain}
    )
  end

  defp merge_event_metadata(%Event{} = event, metadata) when is_map(metadata) do
    %{event | metadata: Metadata.merge_run_metadata(metadata, event.metadata)}
  end

  defp normalize_checkpoint_metadata(metadata), do: metadata

  defp resolved_backend_info(info, resolution, pid) do
    fallback =
      normalize_backend_info(info, resolution, pid)
      |> normalize_backend_observability(resolution)

    case fetch_backend_info(resolution.backend, pid, resolution) do
      %BackendInfo{} = refreshed ->
        normalize_backend_observability(refreshed, resolution)

      _other ->
        fallback
    end
  end

  defp normalize_backend_info(info, resolution, pid) do
    case info do
      %BackendInfo{} = normalized ->
        BackendInfo.normalize(normalized,
          provider: resolution.provider.name,
          lane: resolution.lane,
          backend: resolution.backend,
          session_pid: pid
        )

      other ->
        BackendInfo.normalize(other,
          provider: resolution.provider.name,
          lane: resolution.lane,
          backend: resolution.backend,
          runtime: resolution.backend,
          capabilities: resolution.capabilities,
          session_pid: pid
        )
    end
  end

  defp fetch_backend_info(backend, pid, resolution) when is_atom(backend) and is_pid(pid) do
    backend.info(pid)
    |> normalize_backend_info(resolution, pid)
  rescue
    _error ->
      nil
  catch
    :exit, _reason ->
      nil
  end

  defp normalize_backend_observability(%BackendInfo{} = info, resolution) do
    %{info | observability: backend_observability(info, resolution)}
  end

  defp backend_observability(%BackendInfo{} = info, resolution) do
    capabilities =
      case info.capabilities do
        [] -> resolution.capabilities
        values -> values
      end

    resolution.observability
    |> Map.merge(info.observability)
    |> Map.put(:provider, info.provider || resolution.provider.name)
    |> Map.put(:lane, info.lane || resolution.lane)
    |> Map.put(:backend, info.backend || resolution.backend)
    |> Map.put(:runtime, info.runtime || resolution.backend)
    |> Map.put(:capabilities, capabilities)
  end

  defp execution_mode(%Run.State{execution_config: %ASM.Execution.Config{execution_mode: mode}})
       when mode in [:local, :remote_node],
       do: mode

  defp execution_mode(_state), do: :local

  defp backend_override_lane(lane) when lane in [:core, :sdk], do: lane
  defp backend_override_lane(_lane), do: :core

  defp backend_override_capabilities(%Provider{} = provider, :core) do
    module_capabilities(provider.core_profile)
  end

  defp backend_override_capabilities(%Provider{} = provider, :sdk) do
    module_capabilities(provider.sdk_runtime)
  end

  defp validate_backend_override(_provider, _backend, nil), do: :ok
  defp validate_backend_override(_provider, ASM.ProviderBackend.Core, %{}), do: :ok

  defp validate_backend_override(%Provider{} = provider, backend, %{ref: ref}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "backend override #{inspect(backend)} is unavailable while provider runtime profile #{inspect(ref)} is active for #{inspect(provider.name)}",
       provider: provider.name,
       cause: %{provider: provider.name, backend: backend, provider_runtime_profile_ref: ref}
     )}
  end

  defp module_capabilities(module) when is_atom(module) do
    if function_exported?(module, :capabilities, 0) do
      module.capabilities()
    else
      []
    end
  end
end
