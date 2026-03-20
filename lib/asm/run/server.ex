defmodule ASM.Run.Server do
  @moduledoc """
  Per-run worker that owns backend lifecycle and event fanout.
  """

  use GenServer, restart: :temporary

  alias ASM.{Error, Event, Provider, ProviderRegistry, Run}
  alias CliSubprocessCore.Payload

  @backend_event_tag :cli_subprocess_core_session

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
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
  def init(opts) do
    {:ok, Run.State.new(opts), {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    _ = ASM.Telemetry.run_started(state.session_id, state.run_id, state.provider)

    case start_backend(state) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, %Error{} = error, next_state} ->
        error_event =
          Event.new(
            :error,
            Payload.Error.new(message: error.message, code: to_string(error.kind)),
            run_id: state.run_id,
            session_id: state.session_id,
            provider: state.provider,
            timestamp: DateTime.utc_now()
          )

        next_state =
          next_state
          |> process_events([error_event])
          |> Map.put(:error, error)

        finish_run(next_state)
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
        {@backend_event_tag, ref, {:event, core_event}},
        %{backend_subscription_ref: ref} = state
      ) do
    event =
      Event.wrap_core(
        %{run_id: state.run_id, session_id: state.session_id, provider: state.provider},
        core_event
      )

    consume_event(state, event)
  end

  def handle_info({@backend_event_tag, ref, core_event}, %{backend_subscription_ref: ref} = state) do
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
         start_config <- backend_start_config(provider, state),
         {:ok, pid, info} <- resolution.backend.start_run(start_config),
         :ok <- detach_backend_link(pid),
         :ok <- subscribe_backend(resolution.backend, pid, start_config.subscription_ref),
         next_state <- put_backend_state(state, resolution, pid, info, start_config),
         :ok <- deliver_prompt(next_state) do
      {:ok, next_state}
    else
      {:error, %Error{} = error} ->
        {:error, error, state}

      {:error, reason} ->
        {:error,
         Error.new(:runtime, :runtime, "backend start failed: #{inspect(reason)}", cause: reason),
         state}
    end
  end

  defp resolve_backend(_provider, %Run.State{backend: backend}) when is_atom(backend) do
    {:ok, %{backend: backend, lane: :core, observability: %{provider: :test, lane: :test}}}
  end

  defp resolve_backend(provider, %Run.State{} = state) do
    execution_mode =
      case state.execution_config do
        %ASM.Execution.Config{execution_mode: mode} -> mode
        _ -> :local
      end

    ProviderRegistry.resolve(provider.name,
      lane: state.lane || :auto,
      execution_mode: execution_mode
    )
  end

  defp backend_start_config(provider, state) do
    subscription_ref = make_ref()

    %{
      provider: provider,
      prompt: state.prompt,
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

    %{
      state
      | backend: resolution.backend,
        backend_pid: pid,
        backend_ref: ref,
        backend_subscription_ref: start_config.subscription_ref,
        backend_info: Map.merge(resolution.observability, normalize_backend_info(info)),
        lane: resolution.lane,
        metadata: Map.merge(state.metadata, resolution.observability)
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
            Payload.Error.new(message: error.message, code: to_string(error.kind)),
            run_id: next_state.run_id,
            session_id: next_state.session_id,
            provider: next_state.provider,
            timestamp: DateTime.utc_now()
          )

        finish_run(process_events(next_state, [error_event]))
    end
  end

  defp apply_pipeline(state, event) do
    case ASM.Pipeline.run(event, state.pipeline, state.pipeline_ctx) do
      {:ok, events, pipeline_ctx} ->
        {:ok, events, %{state | pipeline_ctx: pipeline_ctx}}

      {:error, %Error{} = error, pipeline_ctx} ->
        {:error, error, %{state | pipeline_ctx: pipeline_ctx}}
    end
  rescue
    error ->
      {:error, Error.new(:runtime, :runtime, Exception.message(error), cause: error), state}
  end

  defp process_events(state, events) when is_list(events) do
    Enum.reduce(events, state, fn event, acc ->
      next_state = Run.EventReducer.apply_event!(acc, event)
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

  defp normalize_backend_info(%{} = info), do: info
  defp normalize_backend_info(other), do: %{session: other}
end
